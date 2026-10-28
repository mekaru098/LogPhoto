import AVFoundation
import AudioToolbox
import CoreImage
import ImageIO
import Photos
import UIKit

/// Log Photo v1.12 - iPhone 16 Pro / Apple Log（第1世代）向け
///
/// v1.12 の変更:
/// - RAW+Log とレンズ切替の見直し。フォーマットの決定を「モード＋デバイス」で一度に行い
///   （applyDeviceConfiguration がモードを見て Log 用 / RAW 用のフォーマットを選ぶ）、
///   切替時に Log → RAW と二重に再構成していたのをやめた。進行中の RAW ポーリングは
///   トークンで無効化し、古いポーリングが新しい構成を壊さないようにした。
/// - ズーム操作のたびに reconcileInput() が走って RAW セットアップが再試行され、
///   失敗時に無限ループ（点滅）していたのを修正。レンズ切替が必要なときだけ再構成する。
/// - 撮影時の例外クラッシュ対策: photoOutput.maxPhotoQualityPrioritization を .quality に
///   引き上げ（設定側が上限を超えると例外）、フォーマット変更のたびに maxPhotoDimensions を
///   有効な値へ更新する。
/// - RAW 撮影は DNG と Log 変換画像の 2 枚にした（余計な HEVC の 3 枚目を廃止）。
/// - 望遠レンズ（5x など）を追加。表示倍率に応じて 超広角 / 広角 / 望遠 を切り替える。
///   レンズごとの表示倍率は仮想デバイスの切替倍率から求める（なければ 0.5 / 1 / 5）。
/// - タップAF後にシーンが変わったら自動AF/AEへ戻す（subjectAreaDidChange）。
/// - 公開する倍率（zoomFactor）は管理値 desiredZoom に統一し、レンズ切替待ちの間も
///   表示がぶれないようにした。
///
/// v1.11 の変更:
/// - ズーム操作を定番方式に作り替え: スライダーは UI 側の値で完結させ、
///   レンズ切替にはデバウンスを入れて、境界での往復切替を防ぐ。
/// - AF をワンショット方式にしてタップ位置で明確に合焦させる。
///
/// v1.10 の変更:
/// - 倍率の唯一の管理値を desiredZoom（表示倍率）とし、デバイス切替時は
///   デバイス側の残り倍率を読み戻さない。タップAFを追加。
///
/// v1.9: マクロ（超広角）と 0.5倍を追加。 v1.8: RAW の倍率をプレビューに合わせた。
/// v1.7: RAW の段階対策と 4:3 画角。 v1.6: RAW のちらつき修正。 v1.5: マニュアル時のちらつき修正。
/// v1.4: 自前プレビュー（LUT 反映）、マニュアル/RAW は実カメラで動かす。
///
/// 2つの撮影モード:
/// - 方式A (.logFrame): Apple Log のビデオフレームをシャッター時に静止画保存
/// - 方式B (.rawLog): Bayer RAW で撮影し、(1) DNG をそのまま保存、
///   (2) RAW を現像して Log カーブ（近似）で変換した画像も保存する
/// 方式Bの Log 変換は Apple Log の厳密な OETF ではなく近似カーブ。
final class LogPhotoCamera: NSObject, ObservableObject {

    enum CaptureMode: String, CaseIterable, Identifiable {
        case logFrame = "Logフレーム"
        case rawLog = "RAW+Log"
        var id: String { rawValue }
    }

    enum OutputFormat: String, CaseIterable, Identifiable {
        case jpeg = "JPEG"
        case tiff = "TIFF"
        var id: String { rawValue }
    }

    @Published var appleLogAvailable = false   // 現在のレンズに Log フォーマットがある
    @Published var appleLogActive = false      // 実際に activeColorSpace == .appleLog になっている
    @Published var activeLensName = "広角"      // 現在のレンズ名（検証表示用）
    @Published var frameFormatCode = ""        // プレビューフレームの画素形式（例: x422）
    @Published var rawAvailable = false
    @Published var statusText = "準備中…"
    @Published var mode: CaptureMode = .logFrame
    /// 表示倍率（レンズ基準: 広角 = 1x）。管理値 desiredZoom をそのまま公開する。
    @Published var zoomFactor: CGFloat = 1.0
    @Published var zoomPresets: [CGFloat] = [1.0]
    @Published var zoomRange: ClosedRange<CGFloat> = 1.0...1.0
    @Published var lastThumbnail: UIImage?

    // 保存形式・画角・LUT
    @Published var outputFormat: OutputFormat = .jpeg
    @Published var aspectFourThree: Bool = UserDefaults.standard.bool(forKey: "logphoto.aspect43")
    @Published var lutNames: [String] = ["なし"]
    @Published var selectedLUTName: String = "なし"
    private let lutStore = LUTStore()
    private var lutEntries: [String: LUTStore.Entry] = [:]
    private let lutLock = NSLock()
    private var activeLUTSnapshot: LUTStore.Entry?

    // マニュアル撮影
    @Published var manualMode = false
    @Published var shutterSeconds: Double = 1.0 / 60
    @Published var isoValue: Double = 100
    @Published var focusPosition: Double = 0.5
    @Published var whiteBalanceKelvin: Double = 5200
    @Published var isoRange: ClosedRange<Double> = 50...1600
    @Published var shutterRange: ClosedRange<Double> = (1.0 / 8000)...1.0

    override init() {
        super.init()
        refreshLUTList()
        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaDidChange(_:)),
            name: .AVCaptureDeviceSubjectAreaDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "logphoto.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let ciContext = CIContext()
    /// RAW→Log 変換専用（中間結果をキャッシュせずメモリを抑える）
    private let rawConvertContext = CIContext(options: [.cacheIntermediates: false])
    private let rawConversionQueue = DispatchQueue(label: "logphoto.rawconvert", qos: .utility)
    /// 色管理変換をしないレンダリング用（Log の画素値をそのまま書き出すため）
    private let rawContext = CIContext(options: [.workingColorSpace: NSNull(),
                                                  .outputColorSpace: NSNull()])

    // レンズ。Apple Log は実カメラでしか使えないので、実カメラを倍率で切り替える。
    private var virtualDevice: AVCaptureDevice?   // トリプル/デュアル（倍率算出と最終フォールバック）
    private var wideDevice: AVCaptureDevice?      // 広角（1x）
    private var ultraWideDevice: AVCaptureDevice? // 超広角（0.5x / マクロ）
    private var teleDevice: AVCaptureDevice?      // 望遠（5x など）
    private var lensScales: [String: CGFloat] = [:] // uniqueID → 表示倍率（広角 = 1）
    private var captureDevice: AVCaptureDevice?   // 現在の入力デバイス
    private var configuredMode: CaptureMode?      // 現在のフォーマットが対応しているモード

    private var desiredZoom: CGFloat = 1          // 倍率の唯一の管理値（表示倍率）
    private var zoomLower: CGFloat = 1            // 表示倍率の可動範囲（sessionQueue 用の控え）
    private var zoomUpper: CGFloat = 1
    private var zoomSwitchToken = 0               // レンズ切替デバウンス用
    private let zoomRequestLock = NSLock()
    private var pendingZoomRequest: (factor: CGFloat, ramp: Bool, switchLensNow: Bool)?
    private var zoomApplyScheduled = false
    private var rawSetupToken = 0                 // RAW ポーリングの無効化用
    private var rawUsesPhotoPreset = false
    private var pendingRawZoom: CGFloat = 1       // 撮影時のデバイス倍率（DNG 変換画像のトリミング用）
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0
    @Published var macroMode = false
    @Published var previewFrameSize: CGSize = .zero
    @Published var focusStatus = "AF 自動"

    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var configured = false

    // MARK: - 起動
    func requestAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            await MainActor.run { statusText = "カメラの許可が必要です（設定アプリ）" }
            return
        }
        sessionQueue.async { [weak self] in
            self?.configureIfNeeded()
            if !(self?.session.isRunning ?? true) { self?.session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            if self?.session.isRunning == true { self?.session.stopRunning() }
        }
    }

    // MARK: - セッション構築
    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
                          .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        virtualDevice = discovery.devices.first { $0.isVirtualDevice }
        wideDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        ultraWideDevice = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        teleDevice = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        computeLensScales()
        publishZoomBounds()

        guard let device = desiredDevice(),
              let input = try? AVCaptureDeviceInput(device: device) else {
            setStatus("カメラが見つかりません")
            return
        }
        captureDevice = device

        session.beginConfiguration()
        session.sessionPreset = .inputPriority // カスタムフォーマットを優先
        // 重要: これが true（既定）だと commitConfiguration のたびにセッションが
        // activeColorSpace を sRGB/P3 に上書きし、Apple Log が外れる。
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if session.canAddInput(input) { session.addInput(input) }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "logphoto.frames"))

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        // 設定側で .quality を指定するには出力側の上限を先に上げておく（超えると例外）
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()

        applyVideoRotation()
        applyDeviceConfiguration(device)
    }

    /// レンズごとの表示倍率を仮想デバイスの切替倍率から求める。
    /// 仮想デバイスでは倍率 1.0 が最も広いレンズ（超広角）なので、
    /// 広角の切替倍率で割って「広角 = 1x」に揃える。
    private func computeLensScales() {
        var scales: [String: CGFloat] = [:]
        if let wide = wideDevice { scales[wide.uniqueID] = 1 }
        if let uw = ultraWideDevice { scales[uw.uniqueID] = 0.5 }
        if let tele = teleDevice { scales[tele.uniqueID] = 5 }
        if let virtual = virtualDevice {
            let constituents = virtual.constituentDevices
            let switchOvers = virtual.virtualDeviceSwitchOverVideoZoomFactors
                .map { CGFloat(truncating: $0) }
            if switchOvers.count == constituents.count - 1,
               let wideIndex = constituents.firstIndex(where: {
                   $0.deviceType == .builtInWideAngleCamera
               }) {
                func factor(_ index: Int) -> CGFloat { index == 0 ? 1 : switchOvers[index - 1] }
                let wideFactor = factor(wideIndex)
                if wideFactor > 0 {
                    for (index, dev) in constituents.enumerated() {
                        scales[dev.uniqueID] = factor(index) / wideFactor
                    }
                    scales[virtual.uniqueID] = 1 / wideFactor
                }
            } else {
                scales[virtual.uniqueID] = 1
            }
        }
        lensScales = scales
    }

    private func zoomScale(for device: AVCaptureDevice) -> CGFloat {
        if let scale = lensScales[device.uniqueID] { return scale }
        switch device.deviceType {
        case .builtInUltraWideCamera: return 0.5
        case .builtInTelephotoCamera: return 5
        default: return 1
        }
    }

    /// 使うレンズ一覧（倍率順）。実カメラがなければ仮想デバイスだけ。
    private func lensDevices() -> [AVCaptureDevice] {
        let physical = [ultraWideDevice, wideDevice, teleDevice].compactMap { $0 }
        if !physical.isEmpty { return physical }
        return [virtualDevice].compactMap { $0 }
    }

    private func bestLogFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { $0.supportedColorSpaces.contains(.appleLog) }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
    }

    /// RAW 用フォーマット: 写真解像度が最大で、Log 以外の色空間を持つもの。
    private func bestRawFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let candidates = device.formats.filter { !$0.supportedMaxPhotoDimensions.isEmpty }
        let nonLog = candidates.filter {
            $0.supportedColorSpaces.contains(where: { $0 != .appleLog })
        }
        return (nonLog.isEmpty ? candidates : nonLog).max { a, b in
            if photoArea(a) != photoArea(b) { return photoArea(a) < photoArea(b) }
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }
    }

    /// 表示倍率の可動範囲とプリセットをレンズ構成から一度だけ決める。
    private func publishZoomBounds() {
        let lenses = lensDevices()
        guard !lenses.isEmpty else { return }
        var lower = CGFloat.greatestFiniteMagnitude
        var upper: CGFloat = 1
        for lens in lenses {
            let scale = zoomScale(for: lens)
            let format = bestLogFormat(for: lens) ?? lens.activeFormat
            lower = min(lower, lens.minAvailableVideoZoomFactor * scale)
            upper = max(upper, min(format.videoMaxZoomFactor, 15) * scale)
        }
        upper = min(upper, 15)
        lower = min(lower, upper)
        var presets: [CGFloat] = []
        if ultraWideDevice != nil || lower < 0.75 { presets.append(0.5) }
        presets.append(1)
        if upper >= 2 { presets.append(2) }
        if let tele = teleDevice {
            let teleScale = zoomScale(for: tele)
            if teleScale > 2, teleScale <= upper { presets.append(teleScale) }
        } else if upper >= 5 {
            presets.append(5)
        }
        presets = presets.filter { $0 >= lower - 0.001 && $0 <= upper + 0.001 }
        zoomLower = lower
        zoomUpper = upper
        desiredZoom = min(max(desiredZoom, lower), upper)
        let range = lower...upper
        DispatchQueue.main.async {
            self.zoomRange = range
            self.zoomPresets = presets.isEmpty ? [1.0] : presets
        }
    }

    /// 入力切替のたびにビデオ出力の回転（縦向き）を再適用する。
    private func applyVideoRotation() {
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // 縦向き
        }
    }

    /// 現在のフォーマットで有効な最大写真サイズを photoOutput に反映する。
    /// フォーマット変更後に古い値が残っていると撮影時に例外になるため、変更のたびに呼ぶ。
    /// RAW→Log 変換（CIRAWFilter）のメモリ負荷を抑えるため 13MP 程度までを選ぶ。
    private func applyMaxPhotoDimensions() {
        guard let device = captureDevice else { return }
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        guard !dims.isEmpty else { return }
        func area(_ d: CMVideoDimensions) -> Int { Int(d.width) * Int(d.height) }
        let limit = 13_000_000
        let chosen = dims.filter { area($0) <= limit }.max { area($0) < area($1) }
            ?? dims.min { area($0) < area($1) }
        if let chosen { photoOutput.maxPhotoDimensions = chosen }
    }

    /// モードに応じて Log 用 / RAW 用のフォーマットと色空間をデバイスに設定する
    /// （sessionQueue 上、必要なら session.beginConfiguration の中で呼ぶ）。
    /// 戻り値: 見つかった Log フォーマットの有無。
    @discardableResult
    private func configureFormat(_ device: AVCaptureDevice) -> Bool {
        let targetMode = mode
        let logFormat = bestLogFormat(for: device)
        let format: AVCaptureDevice.Format?
        switch targetMode {
        case .logFrame: format = logFormat
        case .rawLog: format = bestRawFormat(for: device) ?? logFormat
        }
        do {
            try device.lockForConfiguration()
            if let format {
                if device.activeFormat != format { device.activeFormat = format }
                if targetMode == .logFrame, format.supportedColorSpaces.contains(.appleLog) {
                    device.activeColorSpace = .appleLog
                } else if let colorSpace = format.supportedColorSpaces
                            .first(where: { $0 != .appleLog }) ?? format.supportedColorSpaces.first {
                    device.activeColorSpace = colorSpace
                }
                // activeFormat を設定するとセッションは inputPriority に戻る
                rawUsesPhotoPreset = false
            }
            if !device.isSubjectAreaChangeMonitoringEnabled {
                device.isSubjectAreaChangeMonitoringEnabled = true
            }
            device.unlockForConfiguration()
        } catch {
            setStatus("カメラ設定に失敗しました")
        }
        configuredMode = targetMode
        return logFormat != nil
    }

    /// フォーマット設定後の後処理: 可動範囲の公開、写真サイズ、状態表示、倍率の再適用
    /// （sessionQueue 上、session.commitConfiguration の後で呼ぶ）。
    private func finishDeviceConfiguration(_ device: AVCaptureDevice, hasLogFormat: Bool) {
        // 念のため: commit 後に色空間が戻されていたら Log を掛け直す
        if mode == .logFrame,
           device.activeFormat.supportedColorSpaces.contains(.appleLog),
           device.activeColorSpace != .appleLog,
           (try? device.lockForConfiguration()) != nil {
            device.activeColorSpace = .appleLog
            device.unlockForConfiguration()
        }
        // レンズを切り替えた直後は AF/AE を明示的に連続オートへ（望遠で AF が動かない対策）
        if !manualMode {
            resetContinuousAutoFocus(device)
        } else {
            applyManualSettings()
        }
        let rangeFormat = device.activeFormat
        let isoLo = Double(rangeFormat.minISO)
        let isoHi = Double(rangeFormat.maxISO)
        let ssLo = rangeFormat.minExposureDuration.seconds
        let ssHi = min(rangeFormat.maxExposureDuration.seconds, 2.0)
        let currentISO = Double(device.iso)
        let currentSS = device.exposureDuration.seconds
        let logActive = device.activeColorSpace == .appleLog
        let lensName = lensLabel(for: device)
        DispatchQueue.main.async {
            self.focusStatus = "AF 自動"
            if isoHi > isoLo { self.isoRange = isoLo...isoHi }
            if ssHi > ssLo { self.shutterRange = ssLo...ssHi }
            self.isoValue = min(max(currentISO, isoLo), isoHi)
            self.shutterSeconds = min(max(currentSS, ssLo), ssHi)
            self.appleLogAvailable = hasLogFormat
            self.appleLogActive = logActive
            self.activeLensName = lensName
        }
        applyMaxPhotoDimensions()
        switch mode {
        case .logFrame:
            setStatus(logActive ? "Apple Log で撮影できます（\(lensName)）"
                                : "このレンズは Apple Log 非対応です（\(lensName)）")
        case .rawLog:
            setStatus("RAW を準備中…（\(lensName)）")
        }
        // 倍率はデバイス側の残り値ではなく、管理値 desiredZoom を適用する
        applyDesiredZoom(ramp: false)
    }

    /// 旧来の 1 段階版（起動時と RAW 失敗時の復帰用）。
    private func applyDeviceConfiguration(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        let hasLog = configureFormat(device)
        session.commitConfiguration()
        finishDeviceConfiguration(device, hasLogFormat: hasLog)
    }

    private func lensLabel(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "超広角"
        case .builtInTelephotoCamera: return "望遠"
        case .builtInWideAngleCamera: return "広角"
        default: return device.isVirtualDevice ? "仮想" : "カメラ"
        }
    }

    /// 現在の状態から使うべきレンズを決める。
    /// マクロは超広角。それ以外は表示倍率で 超広角(<1x) / 広角 / 望遠(≥望遠倍率) を選ぶ。
    /// RAW・マニュアルも同じ実カメラ上で動く（仮想デバイスは実カメラがないときだけ）。
    private func desiredDevice() -> AVCaptureDevice? {
        if macroMode, let uw = ultraWideDevice { return uw }
        if desiredZoom < 1, let uw = ultraWideDevice { return uw }
        if let tele = teleDevice, desiredZoom >= zoomScale(for: tele) { return tele }
        return wideDevice ?? virtualDevice ?? ultraWideDevice
    }

    /// 入力とフォーマットを現在の状態（レンズ・モード）に合わせる（sessionQueue 上で呼ぶ）。
    /// レンズ切替は「入力の付け替え＋フォーマット設定」を 1 回の begin/commit にまとめ、
    /// セッションの再構成を 1 度で済ませる（切替の体感速度）。
    private func reconcileInput() {
        guard let target = desiredDevice() else { return }
        let deviceChanged = target != captureDevice
        let formatNeedsUpdate = configuredMode != mode
        if deviceChanged || formatNeedsUpdate {
            rawSetupToken += 1 // 進行中の RAW ポーリングを無効化
            var hasLog = false
            session.beginConfiguration()
            if rawUsesPhotoPreset {
                session.sessionPreset = .inputPriority
                rawUsesPhotoPreset = false
            }
            if deviceChanged, let newInput = try? AVCaptureDeviceInput(device: target) {
                for input in session.inputs { session.removeInput(input) }
                hasLog = configureFormat(target) // 入力に加える前に設定しておく
                if session.canAddInput(newInput) { session.addInput(newInput) }
                captureDevice = target
            } else {
                hasLog = configureFormat(target)
            }
            session.commitConfiguration()
            applyVideoRotation()
            finishDeviceConfiguration(target, hasLogFormat: hasLog)
        }
        if mode == .rawLog {
            beginRawSetup()
        } else {
            DispatchQueue.main.async { self.rawAvailable = false }
        }
    }


    private func photoArea(_ format: AVCaptureDevice.Format) -> Int {
        format.supportedMaxPhotoDimensions
            .map { Int($0.width) * Int($0.height) }.max() ?? 0
    }

    /// RAW セットアップ（sessionQueue 上で呼ぶ）。フォーマットは applyDeviceConfiguration が
    /// すでに RAW 用にしているので、ここでは対応形式が現れるのを待つだけ:
    /// 1) 再構成の反映を少し待ちながら確認する
    /// 2) それでも有効にならなければ写真優先プリセット（.photo）へ切り替えて再確認する
    private func beginRawSetup() {
        rawSetupToken += 1
        pollRawTypes(attempt: 0, photoPresetStage: false, token: rawSetupToken)
    }

    private func pollRawTypes(attempt: Int, photoPresetStage: Bool, token: Int) {
        guard token == rawSetupToken, mode == .rawLog else { return }
        if !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            DispatchQueue.main.async { self.rawAvailable = true }
            // 構成変更でリセットされ得る倍率を管理値に合わせ直す
            applyDesiredZoom(ramp: false)
            setStatus("RAW+Log の準備ができました")
            return
        }
        if attempt < 4 {
            sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.pollRawTypes(attempt: attempt + 1, photoPresetStage: photoPresetStage,
                                   token: token)
            }
            return
        }
        if !photoPresetStage {
            // 段階2: 写真優先プリセットで再構成する
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.commitConfiguration()
            rawUsesPhotoPreset = true
            applyVideoRotation()
            applyMaxPhotoDimensions()
            applyDesiredZoom(ramp: false)
            pollRawTypes(attempt: 0, photoPresetStage: true, token: token)
            return
        }
        finishRawSetupFailure()
    }

    private func finishRawSetupFailure() {
        if rawUsesPhotoPreset {
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.commitConfiguration()
            rawUsesPhotoPreset = false
        }
        if let device = captureDevice { applyDeviceConfiguration(device) }
        DispatchQueue.main.async { self.rawAvailable = false }
        setStatus("この構成では RAW が使えませんでした")
    }

    /// モード切替時に UI から呼ばれる。
    func modeChanged() {
        sessionQueue.async { [weak self] in
            self?.reconcileInput()
        }
    }

    /// マクロ（超広角＋近距離AF）の ON/OFF。
    func setMacroMode(_ on: Bool) {
        macroMode = on
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.reconcileInput()
            if on { self.setStatus("マクロ（超広角）: 被写体に近づけます") }
        }
    }

    // MARK: - プレビュー用（LUT 適用済みフレーム）
    /// プレビュー表示用に、最新フレームへ選択中 LUT を適用した CIImage を返す。
    func currentPreviewImage() -> CIImage? {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer else { return nil }
        return applyLUT(to: CIImage(cvPixelBuffer: buffer))
    }

    // MARK: - LUT
    func refreshLUTList() {
        lutStore.reload()
        var entries: [String: LUTStore.Entry] = [:]
        let log709 = LUTStore.builtinLogTo709()
        let mono = LUTStore.builtinMono()
        entries[log709.name] = log709
        entries[mono.name] = mono
        for entry in lutStore.userLUTs { entries[entry.name] = entry }
        lutEntries = entries
        lutNames = ["なし", log709.name, mono.name] + lutStore.userLUTs.map { $0.name }
        let stored = UserDefaults.standard.string(forKey: "logphoto.selectedLUT")
        selectedLUTName = (stored != nil && entries[stored!] != nil) ? stored! : "なし"
        setActiveLUTSnapshot(entries[selectedLUTName])
    }

    func selectLUT(_ name: String) {
        selectedLUTName = name
        UserDefaults.standard.set(name, forKey: "logphoto.selectedLUT")
        setActiveLUTSnapshot(lutEntries[name])
    }

    func importLUT(from url: URL) {
        if let entry = lutStore.importLUT(from: url) {
            refreshLUTList()
            selectLUT(entry.name)
            setStatus("LUT「\(entry.name)」を追加しました")
        } else {
            setStatus("その .cube は読み込めませんでした")
        }
    }

    private func setActiveLUTSnapshot(_ entry: LUTStore.Entry?) {
        lutLock.lock()
        activeLUTSnapshot = entry
        lutLock.unlock()
    }

    private var activeLUT: LUTStore.Entry? {
        lutLock.lock()
        defer { lutLock.unlock() }
        return activeLUTSnapshot
    }

    private func applyLUT(to image: CIImage) -> CIImage {
        guard let lut = activeLUT,
              let filter = CIFilter(name: "CIColorCube",
                                    parameters: ["inputCubeDimension": lut.dimension,
                                                 "inputCubeData": lut.data,
                                                 kCIInputImageKey: image]),
              let out = filter.outputImage else { return image }
        return out
    }

    // MARK: - 露出補正
    /// 露出ターゲットバイアス。lockForConfiguration で囲んで安全に適用する。
    func applyExposureCompensation(_ ev: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                let clamped = max(Double(device.minExposureTargetBias),
                                  min(Double(device.maxExposureTargetBias), ev))
                device.setExposureTargetBias(Float(clamped), completionHandler: nil)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    // MARK: - マニュアル撮影（実カメラでのみ使う）
    func setManualMode(_ on: Bool) {
        manualMode = on
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !on, let device = self.captureDevice {
                // 先に現在のデバイスをオートへ戻してから入力を切り替える
                do {
                    try device.lockForConfiguration()
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    device.unlockForConfiguration()
                } catch { }
            }
            self.reconcileInput()
            if on {
                self.applyManualSettings()
            }
        }
    }

    private func applyManualSettings() {
        guard let device = captureDevice else { return }
        let seconds = min(max(shutterSeconds, shutterRange.lowerBound), shutterRange.upperBound)
        let iso = Float(min(max(isoValue, isoRange.lowerBound), isoRange.upperBound))
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(
                    duration: CMTimeMakeWithSeconds(seconds,
                                                    preferredTimescale: 1_000_000_000),
                    iso: iso, completionHandler: nil)
            }
            if device.isFocusModeSupported(.locked) {
                device.setFocusModeLocked(lensPosition: Float(focusPosition),
                                          completionHandler: nil)
            }
            if device.isWhiteBalanceModeSupported(.locked) {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(whiteBalanceKelvin), tint: 0)
                var gains = device.deviceWhiteBalanceGains(for: values)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
            device.unlockForConfiguration()
        } catch { }
    }

    func updateManualExposure() {
        guard manualMode else { return }
        let seconds = shutterSeconds
        let iso = Float(isoValue)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.custom) {
                    device.setExposureModeCustom(
                        duration: CMTimeMakeWithSeconds(seconds,
                                                        preferredTimescale: 1_000_000_000),
                        iso: iso, completionHandler: nil)
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func updateManualFocus() {
        guard manualMode else { return }
        let position = Float(focusPosition)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func updateManualWhiteBalance() {
        guard manualMode else { return }
        let kelvin = Float(whiteBalanceKelvin)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isWhiteBalanceModeSupported(.locked) {
                    let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: kelvin, tint: 0)
                    var gains = device.deviceWhiteBalanceGains(for: values)
                    let maxGain = device.maxWhiteBalanceGain
                    gains.redGain = min(max(gains.redGain, 1), maxGain)
                    gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                    gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    // MARK: - ズーム
    /// ズームの唯一の入口。表示倍率で desiredZoom を更新し、現在のレンズへ倍率を適用する。
    /// レンズ切替が必要なときは、スライダー/ピンチなら 0.3 秒待ってから（デバウンス）、
    /// 倍率ボタンなら即座に（switchLensNow）切り替える。
    /// 倍率ボタンは ramp で滑らかに、ピンチ/スライダーは ramp なしで即時に反映する。
    /// ピンチ/スライダーは 1 秒に何十回も呼ばれるので、要求はまとめて（コアレス）
    /// 最新の 1 件だけをカメラへ適用する。表示倍率は呼ばれた時点ですぐ公開して、
    /// UI の追従がカメラ側の処理待ちにならないようにする。
    func setZoom(_ factor: CGFloat, ramp: Bool = true, switchLensNow: Bool = false) {
        let clampedDisplay = min(max(factor, zoomLower), zoomUpper)
        if Thread.isMainThread {
            zoomFactor = clampedDisplay
        } else {
            DispatchQueue.main.async { self.zoomFactor = clampedDisplay }
        }
        zoomRequestLock.lock()
        pendingZoomRequest = (clampedDisplay, ramp, switchLensNow)
        let alreadyScheduled = zoomApplyScheduled
        zoomApplyScheduled = true
        zoomRequestLock.unlock()
        guard !alreadyScheduled else { return }
        sessionQueue.async { [weak self] in
            self?.drainZoomRequest()
        }
    }

    private func drainZoomRequest() {
        zoomRequestLock.lock()
        let request = pendingZoomRequest
        pendingZoomRequest = nil
        zoomApplyScheduled = false
        zoomRequestLock.unlock()
        guard let request else { return }
        desiredZoom = min(max(request.factor, zoomLower), zoomUpper)
        if desiredDevice() != captureDevice {
            zoomSwitchToken += 1
            if request.switchLensNow {
                reconcileInput() // applyDeviceConfiguration が倍率も適用する
                return
            }
            let token = zoomSwitchToken
            sessionQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.zoomSwitchToken == token else { return }
                self.reconcileInput()
            }
        }
        applyDesiredZoom(ramp: request.ramp)
    }

    /// desiredZoom を現在のデバイスへ適用する（sessionQueue 上で呼ぶ）。
    /// 公開する倍率は常に desiredZoom（レンズ切替待ちで一時的にデジタルズームが
    /// 足りなくても、表示はぶれない）。
    private func applyDesiredZoom(ramp: Bool) {
        guard let device = captureDevice else { return }
        let scale = zoomScale(for: device)
        let requested = desiredZoom / scale
        let deviceMax = min(device.activeFormat.videoMaxZoomFactor, 15.0)
        let clamped = min(max(requested, device.minAvailableVideoZoomFactor), deviceMax)
        do {
            try device.lockForConfiguration()
            if ramp {
                device.ramp(toVideoZoomFactor: clamped, withRate: 12)
            } else {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
        } catch { return }
        let display = desiredZoom
        DispatchQueue.main.async {
            if self.zoomFactor != display { self.zoomFactor = display }
        }
    }

    // MARK: - AF
    /// タップした場所（プレビューの正規化座標 0...1）にピントと露出を合わせる。
    func focusAt(previewPoint point: CGPoint) {
        guard !manualMode else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            // 縦向きプレビュー座標 → センサーの関心点座標
            let devicePoint = CGPoint(x: point.y, y: 1 - point.x)
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    // ワンショットで明確に合わせる（純正のタップAFと同じ方式）
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    } else if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    } else if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                // シーンが変わったら自動へ戻すための監視
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.focusStatus = "AF（タップ位置）" }
            } catch { }
        }
    }

    /// タップAFの後にシーンが大きく変わったら、純正と同じく自動AF/AEへ戻す。
    @objc private func subjectAreaDidChange(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice,
                  (notification.object as? AVCaptureDevice) == device,
                  !self.manualMode else { return }
            self.resetContinuousAutoFocus(device)
        }
    }

    private func resetContinuousAutoFocus(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.focusStatus = "AF 自動" }
        } catch { }
    }

    // MARK: - シャッター（モードで振り分け）
    func shutter() {
        // 純正と同じシャッター音（マナーモードでは鳴らない）
        AudioServicesPlaySystemSound(1108)
        switch mode {
        case .logFrame: captureLogPhoto()
        case .rawLog: captureRawLogPhoto()
        }
    }

    // MARK: - 方式A: Logフレーム保存
    func captureLogPhoto() {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer else { setStatus("フレーム取得前です。少し待ってください"); return }

        let formatCode = fourCharCode(CVPixelBufferGetPixelFormatType(buffer))
        let isTIFF = outputFormat == .tiff

        // LUT なし & BGRA & フル画角: 画素値をそのまま書き出す（最速・無変換）
        if activeLUT == nil, !aspectFourThree,
           let data = imageDataFromPixelBuffer(buffer, isTIFF: isTIFF) {
            updateThumbnail(from: data)
            savePhotoData(data, completion: logSaveMessage(isTIFF: isTIFF, formatCode: formatCode))
            return
        }
        // それ以外（LUT適用 / TIFF / 非BGRA形式 / 4:3）は色管理なしの CI レンダリング。
        var image = CIImage(cvPixelBuffer: buffer)
        if aspectFourThree { image = cropToFourThree(image) }
        image = applyLUT(to: image)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // TIFF は 16bit で書き出し、10bit の Log フレーム（x422 など）の階調を落とさない
        let data = isTIFF
            ? rawContext.tiffRepresentation(of: image, format: .RGBA16, colorSpace: colorSpace)
            : rawContext.jpegRepresentation(of: image, colorSpace: colorSpace)
        guard let data else {
            setStatus("画像の変換に失敗しました（fmt \(formatCode)）")
            return
        }
        updateThumbnail(from: data)
        savePhotoData(data, completion: logSaveMessage(isTIFF: isTIFF, formatCode: formatCode))
    }

    /// 保存メッセージに「本当に Apple Log だったか」を含める（検証用）。
    private func logSaveMessage(isTIFF: Bool, formatCode: String) -> String {
        let kind = isTIFF ? "Log写真（TIFF 16bit）" : "Log写真"
        let logState = appleLogActive ? "Apple Log" : "⚠︎ Log 無効"
        return "\(kind)を保存しました（\(logState) / \(formatCode)）"
    }

    /// 倍率 factor へのセンタートリミング。
    private func centerCrop(_ image: CIImage, factor: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, factor > 1 else { return image }
        let w = extent.width / factor
        let h = extent.height / factor
        let rect = CGRect(x: extent.minX + (extent.width - w) / 2,
                          y: extent.minY + (extent.height - h) / 2,
                          width: w, height: h)
        return image.cropped(to: rect)
    }

    /// 画角 4:3（縦向き 3:4）へのセンタートリミング。
    private func cropToFourThree(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let target = 3.0 / 4.0 // width / height（縦向き）
        var rect = extent
        if extent.width / extent.height > target {
            let w = extent.height * target
            rect = CGRect(x: extent.minX + (extent.width - w) / 2, y: extent.minY,
                          width: w, height: extent.height)
        } else {
            let h = extent.width / target
            rect = CGRect(x: extent.minX, y: extent.minY + (extent.height - h) / 2,
                          width: extent.width, height: h)
        }
        return image.cropped(to: rect)
    }

    func setAspectFourThree(_ on: Bool) {
        aspectFourThree = on
        UserDefaults.standard.set(on, forKey: "logphoto.aspect43")
    }

    private func fourCharCode(_ code: OSType) -> String {
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                              UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        let text = String(bytes: bytes, encoding: .ascii) ?? "\(code)"
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(code)" : trimmed
    }

    /// BGRA ピクセルバッファの画素値を変換せずに JPEG / TIFF データ化する。
    private func imageDataFromPixelBuffer(_ pixelBuffer: CVPixelBuffer, isTIFF: Bool) -> Data? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byteCount = bytesPerRow * height
        let rawData = Data(bytes: base, count: byteCount)
        guard let provider = CGDataProvider(data: rawData as CFData) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow,
                                    space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                    provider: provider,
                                    decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        let type = (isTIFF ? "public.tiff" : "public.jpeg") as CFString
        guard let destination = CGImageDestinationCreateWithData(
            out, type, 1, nil) else { return nil }
        if isTIFF {
            CGImageDestinationAddImage(destination, cgImage, nil)
        } else {
            CGImageDestinationAddImage(destination, cgImage,
                [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    // MARK: - 方式B: RAW撮影
    /// RAW（DNG）だけを要求する。以前は HEVC の処理済み画像も同時に要求していたため
    /// 1 回のシャッターで 3 枚保存されていた。倍率はデバイス倍率で覚えておく
    /// （望遠レンズでは表示倍率 ≠ デバイス倍率）。
    func captureRawLogPhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard let rawType = self.photoOutput.availableRawPhotoPixelFormatTypes.first else {
                self.setStatus("RAW の準備ができていません。少し待ってから撮影してください")
                self.reconcileInput()
                return
            }
            self.pendingRawZoom = self.captureDevice?.videoZoomFactor ?? 1
            let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
            settings.photoQualityPrioritization = .balanced
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            self.setStatus("RAW撮影中…")
        }
    }

    /// RAW(DNG) から Log変換画像（JPEG / TIFF）を作る。LUT 選択時は適用する。失敗時は nil。
    private func makeLogImageData(fromDNG data: Data, format: OutputFormat) -> Data? {
        guard let rawFilter = CIRAWFilter(imageData: data, identifierHint: "dng"),
              var image = rawFilter.outputImage else { return nil }

        // 撮影時の倍率に合わせてセンタートリミング（DNG 本体はフル画角のまま）
        if pendingRawZoom > 1.01 {
            image = centerCrop(image, factor: pendingRawZoom)
        }

        // ハイライト側の情報を Log カーブに収めるため少し引いてから変換
        if let exposure = CIFilter(name: "CIExposureAdjust",
                                   parameters: [kCIInputImageKey: image, kCIInputEVKey: -1.0]),
           let out = exposure.outputImage {
            image = out
        }

        // Log カーブ（近似）: enc = log2(1 + x * 255) / 8
        let kernelSource = """
        kernel vec4 logEncode(sampler src) {
            vec4 c = sample(src, samplerCoord(src));
            vec3 lin = clamp(c.rgb, 0.0, 1.0);
            vec3 enc = log2(1.0 + lin * 255.0) / 8.0;
            return vec4(enc, c.a);
        }
        """
        if let kernel = CIColorKernel(source: kernelSource),
           let out = kernel.apply(extent: image.extent, arguments: [image]) {
            image = out
        } else if let controls = CIFilter(name: "CIColorControls",
                                          parameters: [kCIInputImageKey: image,
                                                       kCIInputSaturationKey: 0.6,
                                                       kCIInputContrastKey: 0.8]),
                  let out = controls.outputImage {
            image = out // カーネルが使えない環境ではフラット化で代替
        }

        image = applyLUT(to: image)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        switch format {
        case .jpeg:
            return rawConvertContext.jpegRepresentation(of: image, colorSpace: colorSpace)
        case .tiff:
            return rawConvertContext.tiffRepresentation(of: image, format: .RGBA16,
                                                        colorSpace: colorSpace)
        }
    }

    // MARK: - 保存ヘルパー
    /// サムネイルは必ず縮小版だけを作る。UIImage(data:) で全体をデコードすると
    /// 12MP の 16bit TIFF や DNG では数百 MB になり、メモリ不足で落ちる原因になる。
    private func updateThumbnail(from data: Data) {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 240
                  ] as CFDictionary) else { return }
            let image = UIImage(cgImage: cgThumb)
            DispatchQueue.main.async { self.lastThumbnail = image }
        }
    }

    private func savePhotoData(_ data: Data,
                               uniformTypeIdentifier: String? = nil,
                               completion message: String) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                self?.setStatus("写真への保存が許可されていません")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = uniformTypeIdentifier
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { ok, _ in
                self?.setStatus(ok ? message : "保存に失敗しました")
            }
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }
}

// MARK: - フレーム受信（方式A・プレビュー用）
extension LogPhotoCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        latestBuffer = buffer
        bufferLock.unlock()
        // フレームサイズの変化だけを公開する（タップAFの座標変換に使う）
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        if w != lastFrameWidth || h != lastFrameHeight {
            lastFrameWidth = w
            lastFrameHeight = h
            let code = fourCharCode(CVPixelBufferGetPixelFormatType(buffer))
            DispatchQueue.main.async {
                self.previewFrameSize = CGSize(width: w, height: h)
                self.frameFormatCode = code
            }
        }
    }
}

// MARK: - RAW撮影の受け取り（方式B用）
extension LogPhotoCamera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if error != nil { setStatus("RAW撮影に失敗しました"); return }
        guard let data = photo.fileDataRepresentation() else {
            setStatus("RAWデータが取得できませんでした")
            return
        }
        if photo.isRawPhoto {
            // (1) DNG そのまま保存 (2) Log変換画像も保存
            savePhotoData(data,
                          uniformTypeIdentifier: "com.adobe.raw-image",
                          completion: "DNG（RAW）を保存しました")
            updateThumbnail(from: data)
            setStatus("DNG を保存。Log 変換中…")
            // 変換は重い（CIRAWFilter）ので撮影コールバックから外し、1 回ずつ直列に行う
            let format = outputFormat
            rawConversionQueue.async { [weak self] in
                guard let self else { return }
                autoreleasepool {
                    if let converted = self.makeLogImageData(fromDNG: data, format: format) {
                        self.updateThumbnail(from: converted)
                        self.savePhotoData(converted, completion: format == .tiff
                            ? "Log変換TIFFも保存しました"
                            : "Log変換JPEGも保存しました")
                    } else {
                        self.setStatus("DNG は保存。Log 変換は失敗しました")
                    }
                }
            }
        } else {
            updateThumbnail(from: data)
            savePhotoData(data, completion: "写真を保存しました")
        }
    }
}
