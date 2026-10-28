import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// Log Photo v1.11 - iPhone 16 Pro / Apple Log（第1世代）向け
///
/// v1.11 の変更:
/// - ズーム操作を定番方式に作り替え: スライダーは UI 側の値で完結させ、
///   レンズ切替（超広角⇔通常）にはヒステリシス（0.9倍で切替・1.2倍で復帰）と
///   0.3秒のデバウンスを入れて、境界での往復切替（バグの主因）を防ぐ。
/// - AF をワンショット方式にしてタップ位置で明確に合焦させる。倍率とAF状態を
///   画面上部に常時表示する。
///
/// v1.10 の変更:
/// - ズームの不安定さを修正。倍率の唯一の管理値を desiredZoom（表示倍率）とし、
///   デバイス切替時はデバイス側の残り倍率を読み戻さず desiredZoom を適用する。
///   ズームスライダーはカメラ値への直接バインディングに変更（往復同期ループ解消）。
/// - タップした場所にピントと露出を合わせるオートフォーカスを追加。
/// - アプリアイコンをレトロなカメラレンズ調に変更。
///
/// v1.9 の変更:
/// - デザインを v1.7 の見た目に戻した（v1.8 のクラシック調は不採用）。
/// - マクロ機能を追加（超広角カメラへ切り替えて近距離にピントを合わせる）。
/// - 0.5倍を追加（超広角カメラへの切替えで実現。表示倍率はレンズ基準で統一し、
///   超広角ではデバイス倍率×0.5 を表示する）。
///
/// v1.8 の変更:
/// - RAW+Log の倍率がプレビューと一致しない問題を修正。静止画側のズームは
///   写真コネクションの videoScaleAndCropFactor が担うため、ズーム操作時に
///   そちらへも倍率を反映し、RAW セットアップ完了時にも再適用する。
///   変換画像（DNG からの書き出し）は撮影時の倍率でセンタートリミングする。
/// - UI のアイコン/ボタンを昔の iOS 風（光沢のあるスキューモーフィック調）に変更。
///
/// v1.7 の変更:
/// - RAW が有効にならない問題への段階対策: RAW用フォーマットへ切り替えた後、
///   対応形式の読み取りを少し待って再確認し（パイプライン再構成との競合対策）、
///   それでもダメなら RAW モード中はセッションを写真優先プリセット（.photo）に
///   切り替える（RAW が確実に使える構成）。Logフレームへ戻ると復帰する。
/// - 画角 4:3 を追加（プレビューのマスク表示と、方式Aの保存時センタートリミング）。
///
/// v1.6 の変更:
/// - RAW+Log でちらつく問題を修正。フォーマット探索のループをやめ、
///   写真の最大解像度が最大のフォーマットへ1回だけ切り替える方式にした。
///   あわせて、その際に Log 色空間を強制しないようにした（Log 色空間の
///   ままでは RAW が有効にならない可能性があった）。
///
/// v1.5 の変更:
/// - マニュアルを押すとプレビューがちらつく/真っ暗になる問題を修正。
///   実カメラへ切り替える際に RAW 用フォーマット探索まで走っていたのが原因で、
///   探索は RAW+Log モードのときだけに限定した。
///
/// 2つの撮影モード:
/// - 方式A (.logFrame): Apple Log のビデオフレームをシャッター時に静止画保存
/// - 方式B (.rawLog): Bayer RAW で撮影し、(1) DNG をそのまま保存、
///   (2) RAW を現像して Log カーブ（近似）で変換した画像も保存する
///
/// v1.4 の変更:
/// - プレビューを自前レンダリング（Core Image + Metal）に変更。選択中の LUT が
///   プレビューにも反映され、保存される Log の見た目がそのまま見える。
/// - マニュアル撮影と RAW 撮影では、入力を実カメラ（広角）に切り替える。
///   仮想デバイス（トリプルカメラ）ではマニュアル系 API が強制終了したり
///   RAW が使えなかったりしたための対策。通常時は仮想デバイスでズームを使う。
/// - 露出補正（ターゲットバイアス）を lockForConfiguration で囲んだ
///   （露出バーを触ると落ちる問題への対策）。
/// - 最後に撮った写真のサムネイルを保持する（UI の左下プレビュー用）。
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

    @Published var appleLogAvailable = false
    @Published var rawAvailable = false
    @Published var statusText = "準備中…"
    @Published var mode: CaptureMode = .logFrame
    @Published var zoomFactor: CGFloat = 1.0
    @Published var zoomPresets: [CGFloat] = [1.0]
    @Published var zoomRange: ClosedRange<CGFloat> = 1.0...1.0
    private var maxZoomFactor: CGFloat = 1.0
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
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "logphoto.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let ciContext = CIContext()
    /// 色管理変換をしないレンダリング用（Log の画素値をそのまま書き出すため）
    private let rawContext = CIContext(options: [.workingColorSpace: NSNull(),
                                                  .outputColorSpace: NSNull()])

    private var virtualDevice: AVCaptureDevice?  // トリプル/デュアル（ズーム用）
    private var physicalDevice: AVCaptureDevice? // 広角の実カメラ（マニュアル/RAW用）
    private var ultraWideDevice: AVCaptureDevice? // 超広角の実カメラ（0.5倍/マクロ用）
    private var captureDevice: AVCaptureDevice?  // 現在の入力デバイス
    private var displayScale: CGFloat = 1        // 表示倍率 = デバイス倍率 × scale
    private var desiredZoom: CGFloat = 1         // 倍率の唯一の管理値（表示倍率）
    private var zoomSwitchToken = 0              // レンズ切替デバウンス用
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0
    @Published var macroMode = false
    @Published var previewFrameSize: CGSize = .zero
    @Published var focusStatus = "AF 自動"
    private var rawSetupInFlight = false
    private var rawUsesPhotoPreset = false
    private var pendingRawZoom: CGFloat = 1

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
            deviceTypes: [.builtInTripleCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        virtualDevice = discovery.devices.first {
            $0.deviceType == .builtInTripleCamera || $0.deviceType == .builtInDualCamera
        }
        physicalDevice = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                 for: .video, position: .back)
        if physicalDevice == nil { physicalDevice = discovery.devices.first }
        ultraWideDevice = AVCaptureDevice.default(.builtInUltraWideCamera,
                                                  for: .video, position: .back)
        // 仮想デバイスに Log がなければ最初から実カメラを使う
        var startDevice = virtualDevice ?? physicalDevice
        if let candidate = startDevice,
           !candidate.formats.contains(where: { $0.supportedColorSpaces.contains(.appleLog) }),
           let wide = physicalDevice,
           wide.formats.contains(where: { $0.supportedColorSpaces.contains(.appleLog) }) {
            startDevice = wide
        }
        guard let device = startDevice,
              let input = try? AVCaptureDeviceInput(device: device) else {
            setStatus("カメラが見つかりません")
            return
        }
        captureDevice = device

        session.beginConfiguration()
        session.sessionPreset = .inputPriority // カスタムフォーマットを優先
        if session.canAddInput(input) { session.addInput(input) }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "logphoto.frames"))

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        applyVideoRotation()
        applyDeviceConfiguration(device)
    }

    /// 入力切替のたびにビデオ出力の回転（縦向き）を再適用する。
    private func applyVideoRotation() {
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // 縦向き
        }
    }

    /// デバイスの Log フォーマット選択と、可動範囲の公開（sessionQueue 上で呼ぶ）。
    private func applyDeviceConfiguration(_ device: AVCaptureDevice) {
        let logFormat = device.formats
            .filter { $0.supportedColorSpaces.contains(.appleLog) }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
        do {
            try device.lockForConfiguration()
            if let logFormat {
                device.activeFormat = logFormat
                device.activeColorSpace = .appleLog
                DispatchQueue.main.async { self.appleLogAvailable = true }
                setStatus("Apple Log で撮影できます")
            } else {
                setStatus("この機種/レンズは Apple Log 非対応です")
            }
            // 表示倍率はレンズ基準: 超広角ではデバイス倍率×0.5 を表示する
            let scale: CGFloat = device.deviceType == .builtInUltraWideCamera ? 0.5 : 1
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 15.0)
            var presets = [CGFloat(0.5), 1.0, 2.0, 5.0].filter { display in
                let dev = display / scale
                return dev >= device.minAvailableVideoZoomFactor - 0.001 && dev <= maxZoom
            }
            // 超広角へ切り替えれば 0.5倍も選べるようにする
            if scale == 1, ultraWideDevice != nil, !presets.contains(0.5) {
                presets.insert(0.5, at: 0)
            }
            let rangeFormat = logFormat ?? device.activeFormat
            let isoLo = Double(rangeFormat.minISO)
            let isoHi = Double(rangeFormat.maxISO)
            let ssLo = rangeFormat.minExposureDuration.seconds
            let ssHi = min(rangeFormat.maxExposureDuration.seconds, 2.0)
            let currentISO = Double(device.iso)
            let currentSS = device.exposureDuration.seconds
            // スライダーの下限は、超広角へ切り替えられる場合は 0.5 まで含める
            let rangeLower = (ultraWideDevice != nil && scale == 1)
                ? min(device.minAvailableVideoZoomFactor * scale, 0.5)
                : device.minAvailableVideoZoomFactor * scale
            DispatchQueue.main.async {
                self.maxZoomFactor = maxZoom
                self.displayScale = scale
                self.focusStatus = "AF 自動"
                self.zoomPresets = presets.isEmpty ? [1.0] : presets
                self.zoomRange = rangeLower...(maxZoom * scale)
                if isoHi > isoLo { self.isoRange = isoLo...isoHi }
                if ssHi > ssLo { self.shutterRange = ssLo...ssHi }
                self.isoValue = min(max(currentISO, isoLo), isoHi)
                self.shutterSeconds = min(max(currentSS, ssLo), ssHi)
            }
            device.unlockForConfiguration()
        } catch {
            setStatus("カメラ設定に失敗しました")
        }
        // 倍率はデバイス側の残り値ではなく、管理値 desiredZoom を適用する
        applyDesiredZoom(ramp: false)
    }

    /// 現在の状態から使うべきデバイスを決める。
    /// RAW は広角の実カメラ、マクロ/0.5倍は超広角、マニュアルは広角の実カメラ。
    private func desiredDevice() -> AVCaptureDevice? {
        if mode == .rawLog { return physicalDevice ?? virtualDevice }
        // レンズ切替にはヒステリシスを持たせる（境界での往復防止）
        let onUltraWide = captureDevice?.deviceType == .builtInUltraWideCamera
        let wantsUltraWide = onUltraWide ? desiredZoom < 1.2 : desiredZoom < 0.9
        if (macroMode || wantsUltraWide), mode == .logFrame, let uw = ultraWideDevice {
            return uw
        }
        if manualMode { return physicalDevice ?? virtualDevice }
        return virtualDevice ?? physicalDevice
    }

    /// 入力を desiredDevice() に合わせる（sessionQueue 上で呼ぶ）。
    private func reconcileInput() {
        // RAW 用に写真優先プリセットへ寄せていたら先に戻す
        if mode != .rawLog, rawUsesPhotoPreset {
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.commitConfiguration()
            rawUsesPhotoPreset = false
        }
        guard let target = desiredDevice() else { return }
        if target != captureDevice {
            guard let newInput = try? AVCaptureDeviceInput(device: target) else { return }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            if session.canAddInput(newInput) { session.addInput(newInput) }
            session.commitConfiguration()
            captureDevice = target
            applyVideoRotation()
            applyDeviceConfiguration(target)
        }
        if mode == .rawLog { beginRawSetup() }
    }

    private func photoArea(_ format: AVCaptureDevice.Format) -> Int {
        format.supportedMaxPhotoDimensions
            .map { Int($0.width) * Int($0.height) }.max() ?? 0
    }

    /// RAW セットアップ（sessionQueue 上で呼ぶ）。段階的に構成を変えて試す:
    /// 1) RAW用フォーマット（写真解像度最大・Log以外の色空間）へ切替えて少し待つ
    /// 2) それでも有効にならなければ写真優先プリセット（.photo）へ切り替える
    private func beginRawSetup() {
        guard !rawSetupInFlight else { return }
        if !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            DispatchQueue.main.async { self.rawAvailable = true }
            return
        }
        guard let device = captureDevice else { return }
        rawSetupInFlight = true
        if let format = device.formats.max(by: { photoArea($0) < photoArea($1) }),
           !format.supportedMaxPhotoDimensions.isEmpty {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let nonLog = format.supportedColorSpaces.first { $0 != .appleLog }
                    ?? format.supportedColorSpaces.first
                if let nonLog { device.activeColorSpace = nonLog }
                device.unlockForConfiguration()
            } catch { }
        }
        pollRawTypes(attempt: 0, photoPresetStage: false)
    }

    private func pollRawTypes(attempt: Int, photoPresetStage: Bool) {
        guard mode == .rawLog else {
            rawSetupInFlight = false
            return
        }
        if !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            rawSetupInFlight = false
            DispatchQueue.main.async { self.rawAvailable = true }
            // 構成変更でリセットされ得る倍率を管理値に合わせ直す
            applyDesiredZoom(ramp: false)
            setStatus("RAW+Log の準備ができました")
            return
        }
        if attempt < 4 {
            sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.pollRawTypes(attempt: attempt + 1, photoPresetStage: photoPresetStage)
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
            pollRawTypes(attempt: 0, photoPresetStage: true)
            return
        }
        finishRawSetupFailure()
    }

    private func finishRawSetupFailure() {
        rawSetupInFlight = false
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
    /// 倍率ボタンは ramp で滑らかに、ピンチ/スライダーは ramp なしで即時に反映する。
    /// ズームの唯一の入口。表示倍率で desiredZoom を更新し、必要ならデバイスを
    /// 切り替えてから、現在のデバイスへ倍率を適用する。
    /// レンズ切替が絡むときだけ 0.3 秒待ってから切り替える（デバウンス）:
    /// スライダーやピンチで境界を往復しても切替が暴走しない。
    func setZoom(_ factor: CGFloat, ramp: Bool = true) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let lower: CGFloat = self.ultraWideDevice != nil ? 0.5 : 1.0
            self.desiredZoom = min(max(factor, lower), 15)
            let needsLensSwitch = self.desiredDevice() != self.captureDevice
            if needsLensSwitch, self.mode == .logFrame, !self.macroMode {
                self.zoomSwitchToken += 1
                let token = self.zoomSwitchToken
                self.sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.zoomSwitchToken == token else { return }
                    self.reconcileInput()
                    self.applyDesiredZoom(ramp: false)
                }
            } else {
                self.reconcileInput()
            }
            self.applyDesiredZoom(ramp: ramp)
        }
    }

    private func zoomScale(for device: AVCaptureDevice) -> CGFloat {
        device.deviceType == .builtInUltraWideCamera ? 0.5 : 1
    }

    /// desiredZoom を現在のデバイスへ適用する（sessionQueue 上で呼ぶ）。
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
        // 超広角でないデバイスでは 1倍未満の希望は保持しない（モードを戻したときに飛ばないよう）
        if device.deviceType != .builtInUltraWideCamera, desiredZoom < 1 {
            desiredZoom = clamped * scale
        }
        DispatchQueue.main.async { self.zoomFactor = clamped * scale }
        // 静止画（RAW）側の倍率は写真コネクションのクロップ率が担うので両方に反映
        applyStillZoom(clamped)
    }

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
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.focusStatus = "AF（タップ位置）" }
            } catch { }
        }
    }

    /// 写真コネクションへ倍率を反映する（sessionQueue 上で呼ぶ）。
    private func applyStillZoom(_ factor: CGFloat) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        connection.videoScaleAndCropFactor = min(max(factor, 1),
                                                 connection.videoMaxScaleAndCropFactor)
    }

    // MARK: - シャッター（モードで振り分け）
    func shutter() {
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
            savePhotoData(data, completion: isTIFF
                ? "Log写真（TIFF）を保存しました（fmt \(formatCode)）"
                : "Log写真を保存しました（fmt \(formatCode)）")
            return
        }
        // それ以外（LUT適用 / TIFF / 非BGRA形式 / 4:3）は色管理なしの CI レンダリング。
        var image = CIImage(cvPixelBuffer: buffer)
        if aspectFourThree { image = cropToFourThree(image) }
        image = applyLUT(to: image)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let data = isTIFF
            ? rawContext.tiffRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace)
            : rawContext.jpegRepresentation(of: image, colorSpace: colorSpace)
        guard let data else {
            setStatus("画像の変換に失敗しました（fmt \(formatCode)）")
            return
        }
        updateThumbnail(from: data)
        savePhotoData(data, completion: isTIFF
            ? "Log写真（TIFF）を保存しました（fmt \(formatCode)）"
            : "Log写真を保存しました（fmt \(formatCode)）")
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
    func captureRawLogPhoto() {
        guard let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            setStatus("RAW の準備ができていません。モードを切り替えて少し待ってください")
            modeChanged()
            return
        }
        pendingRawZoom = zoomFactor
        let settings = AVCapturePhotoSettings(
            rawPixelFormatType: rawType,
            processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc]
        )
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
        setStatus("RAW撮影中…")
    }

    /// RAW(DNG) から Log変換画像（JPEG / TIFF）を作る。LUT 選択時は適用する。失敗時は nil。
    private func makeLogImageData(fromDNG data: Data) -> Data? {
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
        switch outputFormat {
        case .jpeg:
            return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace)
        case .tiff:
            return ciContext.tiffRepresentation(of: image, format: .RGBA16,
                                                colorSpace: colorSpace)
        }
    }

    // MARK: - 保存ヘルパー
    private func updateThumbnail(from data: Data) {
        var image = UIImage(data: data)
        if image == nil,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 200
           ] as CFDictionary) {
            image = UIImage(cgImage: cgThumb)
        }
        guard let image else { return }
        DispatchQueue.main.async { self.lastThumbnail = image }
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
            DispatchQueue.main.async { self.previewFrameSize = CGSize(width: w, height: h) }
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
            if let converted = makeLogImageData(fromDNG: data) {
                updateThumbnail(from: converted)
                savePhotoData(converted, completion: outputFormat == .tiff
                    ? "Log変換TIFFも保存しました"
                    : "Log変換JPEGも保存しました")
            } else {
                updateThumbnail(from: data)
            }
        } else {
            updateThumbnail(from: data)
            savePhotoData(data, completion: "写真を保存しました")
        }
    }
}
