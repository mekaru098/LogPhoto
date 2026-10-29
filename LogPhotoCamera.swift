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
        case logFrame = "logFrame"
        case rawLog = "rawLog"
        var id: String { rawValue }
        var title: String { self == .logFrame ? L("mode.logFrame") : L("mode.rawLog") }
    }

    enum OutputFormat: String, CaseIterable, Identifiable {
        case jpeg = "JPEG"
        case tiff = "TIFF"
        var id: String { rawValue }
    }

    @Published var appleLogAvailable = false   // 現在のレンズに Log フォーマットがある
    @Published var appleLogActive = false      // 実際に activeColorSpace == .appleLog になっている
    @Published var activeLensName = L("lens.wide")      // 現在のレンズ名（検証表示用）
    @Published var frameFormatCode = ""        // プレビューフレームの画素形式（例: x422）
    @Published var rawAvailable = false
    /// RAW を 48MP（センサーの最大）で撮る。OFF は 12MP。
    @Published var rawHighResolution: Bool = UserDefaults.standard.bool(forKey: "logphoto.raw48")
    @Published var rawMegapixels: Double = 0   // 現在の写真サイズ（検証表示用）
    @Published var rawIsProRAW = false          // RAW+Log が Apple ProRAW で撮るか（48MP 設定時）
    @Published var logFrame10Bit: Bool = UserDefaults.standard.object(forKey: "logphoto.log10bit") as? Bool ?? true
    @Published var statusText = L("status.preparing")
    @Published var mode: CaptureMode = .logFrame
    /// 表示倍率（レンズ基準: 広角 = 1x）。管理値 desiredZoom をそのまま公開する。
    @Published var zoomFactor: CGFloat = 1.0
    @Published var zoomPresets: [CGFloat] = [1.0]
    @Published var zoomRange: ClosedRange<CGFloat> = 1.0...1.0

    // --- レンズ切替方式（オート: 倍率でレンズが自動で変わる / マニュアル: レンズを固定して中でズーム）---
    enum LensSelectionMode: String { case auto, manual }
    struct LensOption: Identifiable, Equatable {
        let id: String          // "uw" / "wide" / "wide2x" / "tele"
        let focalMM: Int        // 35mm 換算の焦点距離表示（13 / 24 / 48 / 120 など）
        let deviceID: String    // 使う実カメラの uniqueID
        let baseZoom: CGFloat   // このレンズの 1x にあたる表示倍率（0.5 / 1 / 2 / 5）
        let maxZoom: CGFloat    // このレンズで出せる最大の表示倍率
    }
    @Published var lensSelectionMode: LensSelectionMode =
        LensSelectionMode(rawValue: UserDefaults.standard.string(forKey: "logphoto.lensMode") ?? "auto") ?? .auto
    @Published var lensOptions: [LensOption] = []
    @Published var selectedLensID: String? = UserDefaults.standard.string(forKey: "logphoto.lensID")
    /// この機種に Apple Log 対応レンズが 1 本もない（15 Pro より前）
    @Published var logUnsupportedDevice = false
    let deviceName = DeviceModel.name
    private var autoZoomLower: CGFloat = 1
    private var autoZoomUpper: CGFloat = 1
    private var lensOptionsStore: [LensOption] = []   // sessionQueue 用の控え
    private var selectedLensStore: String? = UserDefaults.standard.string(forKey: "logphoto.lensID")
    @Published var lastThumbnail: UIImage?

    // 保存形式・画角・LUT
    @Published var outputFormat: OutputFormat = .jpeg
    @Published var aspectFourThree: Bool = UserDefaults.standard.bool(forKey: "logphoto.aspect43")
    @Published var lutNames: [String] = ["なし"]
    @Published var selectedLUTName: String = "なし"
    /// LUT を保存画像にも焼き込むか（false = プレビューだけに当てる。保存は Log のまま）
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
    /// 露出補正の可動範囲（端末の min/maxExposureTargetBias。16 Pro は概ね ±8EV）
    @Published var exposureRange: ClosedRange<Double> = -2...2
    @Published var exposureBias: Double = 0
    /// マニュアル設定のプリセット 5 枠（nil = 空）
    struct ManualPreset: Codable, Equatable {
        var shutterSeconds: Double
        var isoValue: Double
        var focusPosition: Double
        var whiteBalanceKelvin: Double
    }
    @Published var manualPresets: [ManualPreset?] = LogPhotoCamera.loadPresets()
    @Published var activePresetIndex: Int? = nil

    /// シャッター音（Logフレームはアプリが鳴らす音、RAW はシステムの音を抑制できる機種のみ）
    @Published var shutterSoundEnabled: Bool = UserDefaults.standard.object(forKey: "logphoto.shutterSound") as? Bool ?? true
    /// 前回 RAW 撮影中に落ちた場合、その段階（クラッシュ原因の切り分け用）
    @Published var lastCrashStage: String? = nil

    override init() {
        super.init()
        refreshLUTList()
        // 前回の RAW 撮影が完了マークなしで終わっていれば、落ちた段階を表示する
        if let stage = UserDefaults.standard.string(forKey: "logphoto.rawStage") {
            lastCrashStage = stage
            statusText = L("status.lastCrash", stage)
            dlog("crash", "前回の RAW 撮影が途中で終了: \(stage)")
            UserDefaults.standard.removeObject(forKey: "logphoto.rawStage")
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaDidChange(_:)),
            name: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil)
        // セッションの異常・中断・メモリ警告を記録する（切替でおかしくなる原因の切り分け用）
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: AVCaptureSession.runtimeErrorNotification, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionWasInterrupted(_:)),
            name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterruptionEnded(_:)),
            name: AVCaptureSession.interruptionEndedNotification, object: session)
        NotificationCenter.default.addObserver(
            self, selector: #selector(memoryWarningReceived(_:)),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        // バックグラウンドでは GPU が使えないので、RAW→Log 変換の方法を切り替える
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground(_:)),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground(_:)),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    // MARK: - バックグラウンドでの撮影処理の継続
    @objc private func appDidEnterBackground(_ note: Notification) {
        appInBackground = true
        if pendingBackgroundWork > 0 {
            dlog("raw", "バックグラウンドへ。未完了の撮影処理 \(pendingBackgroundWork) 件を続ける（Log 変換は CPU）")
        }
    }

    @objc private func appWillEnterForeground(_ note: Notification) {
        appInBackground = false
    }

    /// 撮影処理（撮影〜保存〜Log 変換）を 1 つ受け付けた。最初の 1 つでバックグラウンド実行の
    /// 時間をもらう（アプリを離れても、もらえた時間（通常 30 秒ほど）は処理を続ける）。
    /// シャッターを押した時点で呼ぶ。結果が届いてから申請すると、先にアプリが裏へ回った場合に
    /// 申請が間に合わず、DNG の保存も変換も止められていた（実測）。
    private func backgroundWorkStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingBackgroundWork += 1
            guard self.backgroundWorkTask == .invalid else { return }
            self.backgroundWorkTask = UIApplication.shared.beginBackgroundTask(withName: "LogPhotoCapture") {
                dlog("raw", "バックグラウンドの時間切れ（未完了の撮影処理 \(self.pendingBackgroundWork) 件。アプリに戻ると続きを処理）")
                self.endBackgroundWorkTask()
            }
            if self.backgroundWorkTask == .invalid {
                dlog("raw", "バックグラウンド実行の時間をもらえなかった（アプリを離れると処理が止まる）")
            }
        }
    }

    /// 1 つの処理が終わった（失敗も含む）。全部終わったら時間を返す。
    private func backgroundWorkFinished() {
        DispatchQueue.main.async {
            self.pendingBackgroundWork = max(0, self.pendingBackgroundWork - 1)
            if self.pendingBackgroundWork == 0 { self.endBackgroundWorkTask() }
        }
    }

    private func endBackgroundWorkTask() {
        guard backgroundWorkTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundWorkTask)
        backgroundWorkTask = .invalid
    }

    // MARK: - セッション監視（ログ＋自動再開）
    /// 直近の自動再開の時刻（sessionQueue 上でのみ使う）。短時間に繰り返すときは諦める。
    private var restartTimes: [Date] = []

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        dlog("session", "runtimeError domain=\(error?.domain ?? "?") code=\(error?.code ?? 0) \(error?.localizedDescription ?? "")")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.restartTimes = self.restartTimes.filter { Date().timeIntervalSince($0) < 30 }
            guard self.restartTimes.count < 3 else {
                dlog("session", "自動再開を断念（30秒以内に3回失敗）")
                self.setStatus(L("status.sessionStopped"))
                return
            }
            self.restartTimes.append(Date())
            if !self.session.isRunning {
                dlog("session", "自動再開 startRunning")
                self.session.startRunning()
            }
        }
    }

    @objc private func sessionWasInterrupted(_ note: Notification) {
        var reason = "?"
        if let value = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let r = AVCaptureSession.InterruptionReason(rawValue: value) {
            reason = "\(r)(\(value))"
        }
        dlog("session", "wasInterrupted reason=\(reason)")
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        dlog("session", "interruptionEnded running=\(session.isRunning)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.session.isRunning {
                dlog("session", "中断後に停止していたため startRunning")
                self.session.startRunning()
            }
        }
    }

    @objc private func memoryWarningReceived(_ note: Notification) {
        let stage = UserDefaults.standard.string(forKey: "logphoto.rawStage") ?? "-"
        dlog("memory", "メモリ警告 mode=\(mode.rawValue) rawStage=\(stage)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "logphoto.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let ciContext = CIContext()
    /// RAW→Log 変換専用（中間結果をキャッシュせずメモリを抑える）。作業空間はリニア sRGB に明示し、
    /// GPU カーネルが受け取る値を CPU 版（linearSRGB で取り出して計算）と同じにする。
    private let rawConvertContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    /// バックグラウンド用。iOS はバックグラウンドで GPU を使わせないので CPU で描く（遅い）。
    /// rawConversionQueue 上でのみ使う。
    private lazy var rawConvertSoftwareContext = CIContext(options: [
        .cacheIntermediates: false, .useSoftwareRenderer: true,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    private lazy var rawSoftwareContext = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .useSoftwareRenderer: true])
    private var lastRawLogPath = ""   // 直近の RAW→Log 変換の方法（GPU / CPU。ログ用）
    // アプリがバックグラウンドにいるか（変換キューから読むのでロックで守る）
    private let appStateLock = NSLock()
    private var appInBackgroundStore = false
    private var appInBackground: Bool {
        get { appStateLock.lock(); defer { appStateLock.unlock() }; return appInBackgroundStore }
        set { appStateLock.lock(); appInBackgroundStore = newValue; appStateLock.unlock() }
    }
    // 未完了の撮影処理（撮影〜保存〜Log 変換）の数と、バックグラウンドで続けるためのタスク（main スレッドでのみ使う）
    private var pendingBackgroundWork = 0
    private var backgroundWorkTask: UIBackgroundTaskIdentifier = .invalid
    private let rawConversionQueue = DispatchQueue(label: "logphoto.rawconvert", qos: .utility)
    private var lastRawLogStats = ""  // 直近の RAW→Log 変換の符号値統計（検証表示用）
    /// 色管理変換をしないレンダリング用（Log の画素値をそのまま書き出すため）
    private let rawContext = CIContext(options: [.workingColorSpace: NSNull(),
                                                  .outputColorSpace: NSNull()])

    // レンズ。Apple Log は実カメラでしか使えないので、実カメラを倍率で切り替える。
    private var virtualDevice: AVCaptureDevice?   // トリプル/デュアル（倍率算出と最終フォールバック）
    private var wideDevice: AVCaptureDevice?      // 広角（1x）
    private var ultraWideDevice: AVCaptureDevice? // 超広角（0.5x / マクロ）
    private var teleDevice: AVCaptureDevice?      // 望遠（5x など）
    private var teleTooClose = false              // 望遠の最短距離より近い → 広角のクロップへ逃がす
    private var teleRetryAt: Date = .distantPast  // 望遠へ戻す再試行の時刻（往復防止）
    private var focusObservation: NSKeyValueObservation?
    private var teleRetryCount = 0                // 近距離クロップからの望遠復帰の試行回数
    private var previewCropFactor: CGFloat = 1    // RAW モードのプレビュー用クロップ倍率（デバイス倍率は 1.0 のまま）
    private var ignoreFramesUntil: CFTimeInterval = 0 // レンズ切替直後のフレームを捨てる期限
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
    private var rawSetupInProgress = false
    private var rawPhotoPresetDeviceIDs = Set<String>()  // .photo プリセットでしか RAW が出なかったレンズ
    private var pendingRawShutterUntil: Date? = nil      // RAW 準備中に押されたシャッター（この時刻まで有効）
    // 撮影ごとの切り出し倍率（DNG 変換画像のトリミング用）。キーは AVCapturePhotoSettings.uniqueID。
    // 変換は撮影より遅れて走るので、1 つの変数だと連写で後の撮影の倍率に上書きされていた。
    private var rawCropByCaptureID: [Int64: CGFloat] = [:]
    private var rawRequestedDimsByCaptureID: [Int64: CMVideoDimensions] = [:] // ProRAW で指定した解像度（検証用）
    private let rawCropLock = NSLock()
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0
    private var lastFramePixelFormat: OSType = 0
    @Published var macroMode = false
    @Published var previewFrameSize: CGSize = .zero
    @Published var focusStatus = L("af.auto")

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
            dlog("session", "カメラ権限なし status=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
            await MainActor.run { statusText = L("status.needPermission") }
            return
        }
        sessionQueue.async { [weak self] in
            self?.configureIfNeeded()
            if !(self?.session.isRunning ?? true) {
                dlog("session", "startRunning")
                self?.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            if self?.session.isRunning == true {
                dlog("session", "stopRunning")
                self?.session.stopRunning()
            }
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
        // この機種に Log 対応レンズが無ければ RAW+Log だけにする
        let anyLog = lensDevices().contains { bestLogFormat(for: $0) != nil }
        if !anyLog {
            DispatchQueue.main.async {
                self.logUnsupportedDevice = true
                self.mode = .rawLog
            }
            mode = .rawLog
        }

        guard let device = desiredDevice(),
              let input = try? AVCaptureDeviceInput(device: device) else {
            dlog("session", "configure: 入力を作れない（desiredDevice が nil か AVCaptureDeviceInput 失敗）")
            setStatus(L("status.noCamera"))
            return
        }
        captureDevice = device
        dlog("session", "configure: device=\(device.localizedName) type=\(device.deviceType.rawValue) mode=\(mode.rawValue) virtual=\(virtualDevice != nil) tele=\(teleDevice != nil) uw=\(ultraWideDevice != nil)")

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
        autoZoomLower = lower
        autoZoomUpper = upper

        // マニュアル用のレンズ枠（機種のレンズ構成から生成。48mm は 24mm の 2x クロップを独立枠に）
        var options: [LensOption] = []
        func lensMax(_ lens: AVCaptureDevice) -> CGFloat {
            let format = bestLogFormat(for: lens) ?? lens.activeFormat
            return min(min(format.videoMaxZoomFactor, 15) * zoomScale(for: lens), 15)
        }
        if let uw = ultraWideDevice {
            options.append(LensOption(id: "uw", focalMM: 13, deviceID: uw.uniqueID,
                                      baseZoom: zoomScale(for: uw), maxZoom: lensMax(uw)))
        }
        if let wide = wideDevice {
            let wmax = lensMax(wide)
            options.append(LensOption(id: "wide", focalMM: 24, deviceID: wide.uniqueID, baseZoom: 1, maxZoom: wmax))
            if wmax >= 2 {
                options.append(LensOption(id: "wide2x", focalMM: 48, deviceID: wide.uniqueID, baseZoom: 2, maxZoom: wmax))
            }
        }
        if let tele = teleDevice {
            let ts = zoomScale(for: tele)
            options.append(LensOption(id: "tele", focalMM: Int((24 * ts).rounded()), deviceID: tele.uniqueID,
                                      baseZoom: ts, maxZoom: max(lensMax(tele), ts)))
        }
        if options.isEmpty, let v = virtualDevice ?? captureDevice {
            options.append(LensOption(id: "wide", focalMM: 24, deviceID: v.uniqueID, baseZoom: 1, maxZoom: lensMax(v)))
        }
        let opts = options
        lensOptionsStore = opts
        if selectedLensStore == nil || !opts.contains(where: { $0.id == selectedLensStore }) {
            selectedLensStore = opts.first(where: { $0.id == "wide" })?.id ?? opts.first?.id
        }
        let selected = selectedLensStore
        DispatchQueue.main.async {
            self.lensOptions = opts
            self.selectedLensID = selected
            self.zoomPresets = presets.isEmpty ? [1.0] : presets
        }
        applyZoomBoundsForMode()
    }

    /// 現在のレンズ切替方式に応じて、倍率の可動範囲を決めて公開する（sessionQueue 上）。
    private func applyZoomBoundsForMode() {
        var lower = autoZoomLower, upper = autoZoomUpper
        if lensSelectionMode == .manual, let opt = currentLensOption() {
            lower = opt.baseZoom
            upper = max(opt.maxZoom, opt.baseZoom)
        }
        zoomLower = lower
        zoomUpper = upper
        desiredZoom = min(max(desiredZoom, lower), upper)
        let range = lower...upper
        let display = desiredZoom
        DispatchQueue.main.async {
            self.zoomRange = range
            self.zoomFactor = display
        }
    }

    private func currentLensOption() -> LensOption? {
        lensOptionsStore.first(where: { $0.id == selectedLensStore })
    }

    private func device(forLensOption opt: LensOption) -> AVCaptureDevice? {
        [ultraWideDevice, wideDevice, teleDevice, virtualDevice].compactMap { $0 }
            .first(where: { $0.uniqueID == opt.deviceID })
    }

    /// レンズ切替方式の変更（設定から）。
    func setLensSelectionMode(_ mode: LensSelectionMode) {
        dlog("lens", "レンズ方式 → \(mode.rawValue)")
        lensSelectionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "logphoto.lensMode")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.teleTooClose = false
            if mode == .manual, let opt = self.currentLensOption() {
                self.desiredZoom = opt.baseZoom
            }
            self.applyZoomBoundsForMode()
            self.reconcileInput()
            self.applyDesiredZoom(ramp: false)
        }
    }

    /// マニュアル方式でレンズを選ぶ。選んだレンズの 1x から始める。
    func selectLens(_ id: String) {
        dlog("lens", "レンズ選択 id=\(id)")
        selectedLensID = id
        UserDefaults.standard.set(id, forKey: "logphoto.lensID")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.selectedLensStore = id
            guard let opt = self.currentLensOption() else { return }
            self.teleTooClose = false
            self.desiredZoom = opt.baseZoom
            self.applyZoomBoundsForMode()
            self.reconcileInput()
            self.applyDesiredZoom(ramp: false)
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
        let chosen: CMVideoDimensions?
        // 48MP は Apple ProRAW のときだけ。通常の Bayer RAW は 48MP を指定しても 12MP しか出ない。
        if mode == .rawLog, rawHighResolution, photoOutput.isAppleProRAWEnabled {
            chosen = dims.max { area($0) < area($1) } // 48MP（対応フォーマットなら）
        } else {
            let limit = 13_000_000
            chosen = dims.filter { area($0) <= limit }.max { area($0) < area($1) }
                ?? dims.min { area($0) < area($1) }
        }
        if let chosen {
            photoOutput.maxPhotoDimensions = chosen
            // 8064x6048 は 48.8MP。四捨五入すると「49MP」になりボタンの「48MP」と合わないので切り捨てる
            let mp = floor(Double(area(chosen)) / 1_000_000)
            let proRAW = photoOutput.isAppleProRAWEnabled
            DispatchQueue.main.async {
                self.rawMegapixels = mp
                self.rawIsProRAW = proRAW
            }
        }
    }

    /// RAW の解像度切替（12MP = Bayer RAW / 48MP = Apple ProRAW）。
    /// ProRAW の有効・無効は出力の再構成になるので、RAW の準備をやり直す。
    func setRawHighResolution(_ on: Bool) {
        rawHighResolution = on
        UserDefaults.standard.set(on, forKey: "logphoto.raw48")
        dlog("raw", "RAW 解像度 → \(on ? "48MP（ProRAW）" : "12MP（Bayer RAW）")")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.mode == .rawLog else { return }
            DispatchQueue.main.async { self.rawAvailable = false }
            self.beginRawSetup()
        }
    }

    /// Log フレームを TIFF で保存するときの階調（10bit = 16bit TIFF / 8bit = 8bit TIFF、約半分の大きさ）。
    /// フレーム自体は Apple Log では常に 10bit（x422）で届く。ビデオ出力を BGRA に指定し直すと
    /// setVideoSettings が例外で落ちるので、出力側は触らず書き出しで切り替える。
    func setLogFrame10Bit(_ on: Bool) {
        logFrame10Bit = on
        UserDefaults.standard.set(on, forKey: "logphoto.log10bit")
        dlog("capture", "Log フレームの TIFF → \(on ? "16bit（10bit の階調）" : "8bit")")
    }

    /// 48MP 設定の RAW+Log では Apple ProRAW を使う。
    private var wantsProRAW: Bool { mode == .rawLog && rawHighResolution }

    /// ProRAW を有効・無効にする（sessionQueue 上）。切り替えたら true。
    /// 出力の再構成になるので begin/commit で囲み、写真サイズも合わせ直す。
    @discardableResult
    private func setProRAWEnabled(_ on: Bool) -> Bool {
        let enable = on && photoOutput.isAppleProRAWSupported
        guard photoOutput.isAppleProRAWEnabled != enable else { return false }
        dlog("raw", "Apple ProRAW → \(enable ? "ON" : "OFF") device=\(captureDevice?.localizedName ?? "nil")")
        session.beginConfiguration()
        photoOutput.isAppleProRAWEnabled = enable
        // 写真サイズも同じ再構成の中で合わせる。commit 後に 48MP へ変えると、その反映が
        // 終わる前（直後）に撮った ProRAW が 12MP 相当（約 20MB）になっていた
        applyMaxPhotoDimensions()
        session.commitConfiguration()
        return true
    }

    /// 撮影に使う RAW 形式。ProRAW が有効ならそれを、なければ Bayer RAW を選ぶ。
    private func preferredRawPixelFormat() -> OSType? {
        let types = photoOutput.availableRawPhotoPixelFormatTypes
        if photoOutput.isAppleProRAWEnabled,
           let pro = types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return pro
        }
        return types.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) ?? types.first
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
            dlog("lens", "configureFormat 失敗 device=\(device.localizedName) mode=\(targetMode.rawValue) \(error.localizedDescription)")
            setStatus(L("status.configFailed"))
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
        // マニュアル中はユーザーの値を維持し（新レンズの範囲にクランプ）、
        // オート中だけデバイスの現在値をスライダーに反映する
        let keepManual = manualMode
        let currentISO = keepManual ? isoValue : Double(device.iso)
        let currentSS = keepManual ? shutterSeconds : device.exposureDuration.seconds
        let logActive = device.activeColorSpace == .appleLog
        installFocusObservation(for: device)
        scheduleTelephotoNearCheck(for: device)
        let lensName = lensLabel(for: device)
            + (teleTooClose && device.deviceType == .builtInWideAngleCamera ? L("lens.nearCrop") : "")
        let biasLo = Double(device.minExposureTargetBias)
        let biasHi = Double(device.maxExposureTargetBias)
        reapplyExposureBias(device)
        DispatchQueue.main.async {
            self.focusStatus = keepManual ? L("af.manual") : L("af.auto")
            if isoHi > isoLo { self.isoRange = isoLo...isoHi }
            if ssHi > ssLo { self.shutterRange = ssLo...ssHi }
            if biasHi > biasLo { self.exposureRange = biasLo...biasHi }
            self.isoValue = min(max(currentISO, isoLo), isoHi)
            self.shutterSeconds = min(max(currentSS, ssLo), ssHi)
            self.appleLogAvailable = hasLogFormat
            self.appleLogActive = logActive
            self.activeLensName = lensName
        }
        applyMaxPhotoDimensions()
        switch mode {
        case .logFrame:
            setStatus(logActive ? L("status.logReady", lensName)
                                : L("status.logUnsupportedLens", lensName))
        case .rawLog:
            setStatus(L("status.rawPreparing", lensName))
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
        case .builtInUltraWideCamera: return L("lens.ultraWide")
        case .builtInTelephotoCamera: return L("lens.tele")
        case .builtInWideAngleCamera: return L("lens.wide")
        default: return device.isVirtualDevice ? L("lens.virtual") : L("lens.camera")
        }
    }

    /// 現在の状態から使うべきレンズを決める。
    /// マクロは超広角。それ以外は表示倍率で 超広角(<1x) / 広角 / 望遠(≥望遠倍率) を選ぶ。
    /// RAW・マニュアルも同じ実カメラ上で動く（仮想デバイスは実カメラがないときだけ）。
    private func desiredDevice() -> AVCaptureDevice? {
        if macroMode, let uw = ultraWideDevice { return uw }
        if lensSelectionMode == .manual, let opt = currentLensOption(), let dev = device(forLensOption: opt) {
            return dev // マニュアル: ユーザーが選んだレンズを固定
        }
        if desiredZoom < 1, let uw = ultraWideDevice { return uw }
        if let tele = teleDevice, desiredZoom >= zoomScale(for: tele), !teleTooClose { return tele }
        return wideDevice ?? virtualDevice ?? ultraWideDevice
    }

    /// 望遠では AF の結果を監視し、レンズが最短位置（lensPosition ≈ 0）で止まったら
    /// 「被写体が望遠の最短撮影距離より近い」と判断して広角のデジタルクロップへ逃がす
    /// （純正カメラと同じ振る舞い）。シーンが変わったら望遠へ戻すのを試す。
    private func installFocusObservation(for device: AVCaptureDevice) {
        focusObservation = nil
        guard device.deviceType == .builtInTelephotoCamera else { return }
        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] dev, change in
            guard let self, change.newValue == false else { return }
            let position = dev.lensPosition
            self.sessionQueue.async { [weak self] in
                self?.handleTelephotoLensPosition(position, device: dev)
            }
        }
    }

    /// 望遠へ切り替えた直後にも AF の結果を確認する（KVO が来ないケースの保険）。
    private func scheduleTelephotoNearCheck(for device: AVCaptureDevice) {
        guard device.deviceType == .builtInTelephotoCamera, !manualMode else { return }
        for delay in [0.6, 1.2] {
            sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.captureDevice == device else { return }
                self.handleTelephotoLensPosition(device.lensPosition, device: device)
            }
        }
    }

    /// 望遠の AF がレンズの最短端（lensPosition ≈ 0）で止まっている = 被写体が最短撮影距離より
    /// 近い。純正と同じく広角の 5x クロップへ逃がす（sessionQueue 上）。
    private func handleTelephotoLensPosition(_ position: Float, device: AVCaptureDevice) {
        guard captureDevice == device, device.deviceType == .builtInTelephotoCamera,
              !manualMode, !teleTooClose, !device.isAdjustingFocus else { return }
        if position < 0.06 {
            if lensSelectionMode == .manual {
                // マニュアルではレンズを尊重し、警告だけ出す
                setStatus(L("lens.tooCloseWarn"))
                return
            }
            teleTooClose = true
            teleRetryAt = Date().addingTimeInterval(5)
            setStatus(L("status.teleFallback"))
            reconcileInput()
        }
    }

    /// 広角クロップへ逃げている間にシーンが変わったら、望遠へ戻せるか試す。
    private func retryTelephotoIfNeeded() {
        guard teleTooClose, Date() >= teleRetryAt, teleRetryCount < 1,
              let tele = teleDevice, desiredZoom >= zoomScale(for: tele) else { return }
        teleTooClose = false
        teleRetryCount += 1
        teleRetryAt = Date().addingTimeInterval(8)
        reconcileInput()
    }

    /// 入力とフォーマットを現在の状態（レンズ・モード）に合わせる（sessionQueue 上で呼ぶ）。
    /// レンズ切替は「入力の付け替え＋フォーマット設定」を 1 回の begin/commit にまとめ、
    /// セッションの再構成を 1 度で済ませる（切替の体感速度）。
    private func reconcileInput() {
        guard let target = desiredDevice() else { return }
        let deviceChanged = target != captureDevice
        let formatNeedsUpdate = configuredMode != mode
        if deviceChanged || formatNeedsUpdate {
            dlog("lens", "reconcile: \(captureDevice?.localizedName ?? "nil") → \(target.localizedName) deviceChanged=\(deviceChanged) formatChanged=\(formatNeedsUpdate) mode=\(mode.rawValue) lensMode=\(lensSelectionMode.rawValue) running=\(session.isRunning)")
            rawSetupToken += 1 // 進行中の RAW ポーリングを無効化
            var hasLog = false
            var activeDevice = target
            var newInput: AVCaptureDeviceInput? = nil
            if deviceChanged {
                do {
                    newInput = try AVCaptureDeviceInput(device: target)
                } catch {
                    dlog("lens", "入力の作成に失敗: \(target.localizedName) \(error.localizedDescription)")
                }
            }
            session.beginConfiguration()
            if rawUsesPhotoPreset {
                session.sessionPreset = .inputPriority
                rawUsesPhotoPreset = false
            }
            // ProRAW は .photo プリセットに戻したあと beginRawSetup で有効にし直す
            // （inputPriority のフォーマットでは非対応のことがある）
            if photoOutput.isAppleProRAWEnabled {
                photoOutput.isAppleProRAWEnabled = false
            }
            if deviceChanged, let newInput {
                let oldInputs = session.inputs
                for input in oldInputs { session.removeInput(input) }
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    // 入力に加えた後・commit の前にフォーマットと色空間を決める（同じトランザクション内）
                    hasLog = configureFormat(target)
                    captureDevice = target
                    ignoreFramesUntil = CACurrentMediaTime() + 0.25
                } else {
                    // 追加できなければ元の入力へ戻す（入力ゼロで captureDevice だけ進むのを防ぐ）
                    dlog("lens", "canAddInput=false: \(target.localizedName)。元の入力へ戻す")
                    for input in oldInputs where session.canAddInput(input) { session.addInput(input) }
                    activeDevice = captureDevice ?? target
                    hasLog = configureFormat(activeDevice)
                }
            } else {
                if deviceChanged { activeDevice = captureDevice ?? target }
                hasLog = configureFormat(activeDevice)
            }
            session.commitConfiguration()
            applyVideoRotation()
            finishDeviceConfiguration(activeDevice, hasLogFormat: hasLog)
            dlog("lens", "reconcile 完了: active=\(activeDevice.localizedName) logFormat=\(hasLog) appleLog=\(activeDevice.activeColorSpace == .appleLog) running=\(session.isRunning)")
        }
        if mode == .rawLog {
            beginRawSetup()
        } else {
            rawSetupInProgress = false
            pendingRawShutterUntil = nil // RAW 以外へ切り替えたら、待っていたシャッターは取り消す
            setProRAWEnabled(false)
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
        rawSetupInProgress = true
        let token = rawSetupToken
        if !wantsProRAW { setProRAWEnabled(false) } // 12MP 設定は Bayer RAW
        // 前に .photo プリセットでしか RAW が出なかったレンズは、0.3 秒 × 5 回待たずにすぐ切り替える
        // （レンズを替えるたびに約 1.5 秒、撮影できない時間ができていた）
        if !rawUsesPhotoPreset, photoOutput.availableRawPhotoPixelFormatTypes.isEmpty,
           let id = captureDevice?.uniqueID, rawPhotoPresetDeviceIDs.contains(id) {
            switchRawToPhotoPreset(token: token, reason: "前回 .photo が必要だったレンズ")
            return
        }
        pollRawTypes(attempt: 0, photoPresetStage: false, token: token)
    }

    private func pollRawTypes(attempt: Int, photoPresetStage: Bool, token: Int) {
        guard token == rawSetupToken, mode == .rawLog else { return }
        if !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            // 48MP 設定なら、RAW が出たところで ProRAW を有効にして確認し直す
            if wantsProRAW, setProRAWEnabled(true) {
                pollRawTypes(attempt: 0, photoPresetStage: photoPresetStage, token: token)
                return
            }
            if wantsProRAW, !photoOutput.isAppleProRAWSupported, !photoPresetStage {
                // ProRAW は .photo プリセットでなら使えることがあるので試す
                switchRawToPhotoPreset(token: token, reason: "inputPriority では ProRAW 非対応")
                return
            }
            let isProRAW = preferredRawPixelFormat().map { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) } ?? false
            if photoOutput.isAppleProRAWEnabled, !isProRAW, attempt < 4 {
                // ProRAW を有効にした直後で、まだ ProRAW 形式が出ていない
                sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.pollRawTypes(attempt: attempt + 1, photoPresetStage: photoPresetStage,
                                       token: token)
                }
                return
            }
            if photoOutput.isAppleProRAWEnabled, !isProRAW {
                setProRAWEnabled(false) // 待っても ProRAW 形式が出なければ Bayer RAW で撮る
            }
            dlog("raw", "RAW 準備OK kind=\(isProRAW ? "ProRAW" : "Bayer") attempt=\(attempt) photoPreset=\(photoPresetStage) device=\(captureDevice?.localizedName ?? "nil")")
            if wantsProRAW, !isProRAW {
                dlog("raw", "このレンズ・構成では ProRAW が使えないため Bayer RAW（12MP）で撮影 supported=\(photoOutput.isAppleProRAWSupported)")
            }
            if isProRAW, let rawType = preferredRawPixelFormat() {
                // ProRAW は出力側の準備が終わる前に撮ると、48MP を指定しても 12MP で返ってくる（実測）。
                // 撮影設定を前もって準備させ、終わってから「準備OK」にする（その間のシャッターは待たせる）。
                let settings = makeRawPhotoSettings(rawType: rawType)
                let dims = settings.maxPhotoDimensions
                let started = CACurrentMediaTime()
                photoOutput.setPreparedPhotoSettingsArray([settings]) { [weak self] prepared, error in
                    self?.sessionQueue.async {
                        guard let self, token == self.rawSetupToken, self.mode == .rawLog else { return }
                        dlog("raw", "ProRAW の撮影準備 \(prepared ? "OK" : "失敗") \(String(format: "%.2f", CACurrentMediaTime() - started))秒 dims=\(dims.width)x\(dims.height) \(error?.localizedDescription ?? "")")
                        self.finishRawSetupSuccess(photoPresetStage: photoPresetStage)
                    }
                }
                // 準備の完了が届かないまま止まらないよう、3 秒で打ち切って先へ進む
                sessionQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, token == self.rawSetupToken, self.rawSetupInProgress else { return }
                    dlog("raw", "ProRAW の撮影準備が 3 秒で終わらないため、このまま準備OKにする")
                    self.finishRawSetupSuccess(photoPresetStage: photoPresetStage)
                }
                return
            }
            finishRawSetupSuccess(photoPresetStage: photoPresetStage)
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
            switchRawToPhotoPreset(token: token, reason: "RAW 形式が現れない")
            return
        }
        finishRawSetupFailure()
    }

    /// RAW の準備ができた（sessionQueue 上）。撮影を受け付け、待っていたシャッターがあれば撮る。
    private func finishRawSetupSuccess(photoPresetStage: Bool) {
        guard rawSetupInProgress else { return } // 準備完了の通知と打ち切りの両方から呼ばれ得る
        rawSetupInProgress = false
        if photoPresetStage, let id = captureDevice?.uniqueID {
            rawPhotoPresetDeviceIDs.insert(id)
        }
        DispatchQueue.main.async { self.rawAvailable = true }
        // 構成変更でリセットされ得る倍率を管理値に合わせ直す
        applyDesiredZoom(ramp: false)
        setStatus(L("status.rawReady"))
        firePendingRawShutter()
    }

    /// RAW 撮影の設定（撮影と事前準備で同じ内容にする）。
    private func makeRawPhotoSettings(rawType: OSType) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        if AVCapturePhotoOutput.isAppleProRAWPixelFormat(rawType) {
            // ProRAW は写真ごとに解像度を指定しないと 12MP になる（出力側の上限以下にする）。
            // 画質の優先度は既定の .balanced のまま（Bayer と違って .speed の制約はない）。
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        } else {
            // AVFoundation の規則: Bayer RAW では photoQualityPrioritization は .speed 必須
            // （.balanced/.quality は設定時に例外、既定の .balanced のままでも capturePhoto で例外）。
            settings.photoQualityPrioritization = .speed
        }
        // 可能な機種では無音化（日本向け端末では非対応のことが多い）
        if !shutterSoundEnabled, photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
        return settings
    }

    /// 段階2: 写真優先プリセット（.photo）で再構成して RAW 形式を確認する。
    private func switchRawToPhotoPreset(token: Int, reason: String) {
        dlog("raw", "\(reason) → .photo プリセットで再構成 device=\(captureDevice?.localizedName ?? "nil")")
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.commitConfiguration()
        rawUsesPhotoPreset = true
        applyVideoRotation()
        applyMaxPhotoDimensions()
        applyDesiredZoom(ramp: false)
        pollRawTypes(attempt: 0, photoPresetStage: true, token: token)
    }

    /// RAW 準備中に押されたシャッターを、準備ができたところで撮る（sessionQueue 上）。
    private func firePendingRawShutter() {
        guard let until = pendingRawShutterUntil else { return }
        pendingRawShutterUntil = nil
        if Date() <= until {
            dlog("raw", "待っていたシャッターを撮影 device=\(captureDevice?.localizedName ?? "nil")")
            captureRawLogPhoto()
        } else {
            // 押してから時間が経ちすぎた（構図が変わっている）ので撮らず、撮れなかったことを伝える
            dlog("raw", "待っていたシャッターは期限切れのため撮影せず")
            setStatus(L("status.rawShotDropped"))
        }
    }

    private func finishRawSetupFailure() {
        dlog("raw", "RAW セットアップ失敗（.photo プリセットでも形式なし） device=\(captureDevice?.localizedName ?? "nil")")
        rawSetupInProgress = false
        if let id = captureDevice?.uniqueID { rawPhotoPresetDeviceIDs.remove(id) }
        let hadPendingShutter = pendingRawShutterUntil != nil
        pendingRawShutterUntil = nil
        setProRAWEnabled(false)
        if rawUsesPhotoPreset {
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            session.commitConfiguration()
            rawUsesPhotoPreset = false
        }
        if let device = captureDevice { applyDeviceConfiguration(device) }
        DispatchQueue.main.async { self.rawAvailable = false }
        if hadPendingShutter { dlog("raw", "待っていたシャッターは RAW が使えないため撮影せず") }
        setStatus(L(hadPendingShutter ? "status.rawShotDropped" : "status.rawUnavailable"))
    }

    /// モード切替時に UI から呼ばれる。
    func modeChanged() {
        dlog("mode", "モード切替 → \(mode.rawValue)")
        sessionQueue.async { [weak self] in
            self?.reconcileInput()
        }
    }

    /// マクロ（超広角＋近距離AF）の ON/OFF。マクロ中はレンズを選んでもマクロを優先し、
    /// 選んだ画角に合わせて超広角を切り抜く。マクロを切るのはこのボタンだけ。
    func setMacroMode(_ on: Bool) {
        dlog("lens", "マクロ → \(on ? "ON" : "OFF")")
        macroMode = on
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.reconcileInput()
            if on { self.setStatus(L("status.macro")) }
        }
    }

    // MARK: - プレビュー用（LUT 適用済みフレーム）
    /// プレビュー表示用に、最新フレームへ選択中 LUT を適用した CIImage を返す。
    func currentPreviewImage() -> CIImage? {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        // RAW モードはデバイスのズームを使えない（RAW 撮影の要件）ので、プレビューを切り出して倍率を見せる
        let crop = previewCropFactor
        if crop > 1.01 { image = centerCrop(image, factor: crop) }
        return applyLUT(to: image)
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
            setStatus(L("status.lutAdded", entry.name))
        } else {
            setStatus(L("status.lutInvalid"))
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

    /// 保存時に使う LUT。選んだ LUT は常に保存にも焼き込む（「なし」なら Log のまま保存）。
    /// 以前は「表示のみ / 保存にも」を切り替えられたが、分かりにくいので焼き込みに統一した。
    private var savedLUT: LUTStore.Entry? { activeLUT }

    private func applyLUT(to image: CIImage) -> CIImage {
        applyLUT(to: image, entry: activeLUT)
    }

    private func applyLUT(to image: CIImage, entry: LUTStore.Entry?) -> CIImage {
        guard let lut = entry,
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
        exposureBias = ev
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            self.reapplyExposureBias(device)
        }
    }

    /// レンズ切替後にも露出補正を掛け直す（sessionQueue 上）。
    private func reapplyExposureBias(_ device: AVCaptureDevice) {
        let ev = exposureBias
        do {
            try device.lockForConfiguration()
            let clamped = max(Double(device.minExposureTargetBias),
                              min(Double(device.maxExposureTargetBias), ev))
            device.setExposureTargetBias(Float(clamped), completionHandler: nil)
            device.unlockForConfiguration()
        } catch { dlog("device", "reapplyExposureBias 失敗: \(error.localizedDescription)") }
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
                } catch { dlog("device", "setManualMode 失敗: \(error.localizedDescription)") }
            }
            self.reconcileInput()
            if on {
                self.applyManualSettings()
            }
        }
    }

    private func applyManualSettings() {
        guard let device = captureDevice else { return }
        // 範囲は切替先レンズのフォーマットから取る（公開中の範囲は前のレンズのものかもしれない）
        let format = device.activeFormat
        let ssLo = format.minExposureDuration.seconds
        let ssHi = min(format.maxExposureDuration.seconds, 2.0)
        let seconds = min(max(shutterSeconds, ssLo), ssHi)
        let iso = Float(min(max(isoValue, Double(format.minISO)), Double(format.maxISO)))
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
        } catch { dlog("device", "applyManualSettings 失敗: \(error.localizedDescription)") }
    }

    // MARK: - マニュアルプリセット（5 枠、上書き・削除可）
    private static let presetsKey = "logphoto.manualPresets"

    private static func loadPresets() -> [ManualPreset?] {
        var slots: [ManualPreset?] = Array(repeating: nil, count: 5)
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let decoded = try? JSONDecoder().decode([ManualPreset?].self, from: data) {
            for (i, p) in decoded.prefix(5).enumerated() { slots[i] = p }
        }
        return slots
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(manualPresets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }

    func currentManualPreset() -> ManualPreset {
        ManualPreset(shutterSeconds: shutterSeconds, isoValue: isoValue,
                     focusPosition: focusPosition, whiteBalanceKelvin: whiteBalanceKelvin)
    }

    /// 現在値をスロットへ保存（既存があれば上書き）。
    func saveManualPreset(to index: Int) {
        guard manualPresets.indices.contains(index) else { return }
        manualPresets[index] = currentManualPreset()
        activePresetIndex = index
        persistPresets()
        setStatus(L("preset.saved", index + 1))
    }

    func deleteManualPreset(at index: Int) {
        guard manualPresets.indices.contains(index) else { return }
        manualPresets[index] = nil
        if activePresetIndex == index { activePresetIndex = nil }
        persistPresets()
        setStatus(L("preset.deleted", index + 1))
    }

    /// スロットを呼び出してカメラに適用する（マニュアルが OFF なら ON にする）。
    func loadManualPreset(at index: Int) {
        guard manualPresets.indices.contains(index), let preset = manualPresets[index] else { return }
        shutterSeconds = preset.shutterSeconds
        isoValue = preset.isoValue
        focusPosition = preset.focusPosition
        whiteBalanceKelvin = preset.whiteBalanceKelvin
        activePresetIndex = index
        if !manualMode {
            setManualMode(true)
        } else {
            sessionQueue.async { [weak self] in self?.applyManualSettings() }
        }
        setStatus(L("preset.loaded", index + 1))
    }

    /// 値を手で変えたら「呼び出し中」の強調を外す（UI から呼ぶ）。
    func manualValueEdited() {
        guard let i = activePresetIndex, let p = manualPresets[i] else { return }
        let c = currentManualPreset()
        // SS は log2 経由で丸めが入るので、わずかな差は「同じ」とみなす
        let same = abs(log2(max(p.shutterSeconds, 1e-6)) - log2(max(c.shutterSeconds, 1e-6))) < 0.03
            && abs(p.isoValue - c.isoValue) < 1
            && abs(p.focusPosition - c.focusPosition) < 0.011
            && abs(p.whiteBalanceKelvin - c.whiteBalanceKelvin) < 51
        if !same { activePresetIndex = nil }
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
            } catch { dlog("device", "updateManualExposure 失敗: \(error.localizedDescription)") }
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
            } catch { dlog("device", "updateManualFocus 失敗: \(error.localizedDescription)") }
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
            } catch { dlog("device", "updateManualWhiteBalance 失敗: \(error.localizedDescription)") }
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
        if let tele = teleDevice, desiredZoom < zoomScale(for: tele) {
            teleTooClose = false
            teleRetryCount = 0
        } else if request.switchLensNow {
            // 5x チップを押し直したときは望遠をもう一度試す
            teleTooClose = false
            teleRetryCount = 0
        }
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
        // RAW 撮影はデバイスの videoZoomFactor が 1.0 でないと例外になる（AVFoundation の規則）。
        // RAW モードではデバイス側は常に 1.0 にし、倍率はプレビューのクロップで表現する。
        let deviceZoom: CGFloat = mode == .rawLog ? 1.0 : clamped
        previewCropFactor = mode == .rawLog ? clamped : 1.0
        do {
            try device.lockForConfiguration()
            if ramp, mode != .rawLog {
                device.ramp(toVideoZoomFactor: deviceZoom, withRate: 12)
            } else {
                device.cancelVideoZoomRamp()
                if device.videoZoomFactor != deviceZoom { device.videoZoomFactor = deviceZoom }
            }
            device.unlockForConfiguration()
        } catch {
            dlog("zoom", "applyDesiredZoom の lockForConfiguration 失敗: \(error.localizedDescription)")
            return
        }
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
                DispatchQueue.main.async { self.focusStatus = L("af.tap") }
            } catch { dlog("device", "focusAt 失敗: \(error.localizedDescription)") }
        }
    }

    /// タップAFの後にシーンが大きく変わったら、純正と同じく自動AF/AEへ戻す。
    @objc private func subjectAreaDidChange(_ notification: Notification) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice,
                  (notification.object as? AVCaptureDevice) == device,
                  !self.manualMode else { return }
            self.resetContinuousAutoFocus(device)
            self.retryTelephotoIfNeeded()
        }
    }

    private func resetContinuousAutoFocus(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }
            // 静止画向け: なめらかAF（動画用の遅いAF）は切り、顔優先AFは使う
            if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = false }
            if device.isFaceDrivenAutoFocusEnabled == false {
                device.automaticallyAdjustsFaceDrivenAutoFocusEnabled = true
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
            DispatchQueue.main.async { self.focusStatus = L("af.auto") }
        } catch { dlog("device", "resetContinuousAutoFocus 失敗: \(error.localizedDescription)") }
    }

    // MARK: - シャッター（モードで振り分け）
    func setShutterSound(_ on: Bool) {
        shutterSoundEnabled = on
        UserDefaults.standard.set(on, forKey: "logphoto.shutterSound")
    }

    /// RAW 撮影の進行段階を UserDefaults に残す（落ちたときの切り分け用）。
    private func markRawStage(_ stage: String?) {
        if let stage {
            UserDefaults.standard.set(stage, forKey: "logphoto.rawStage")
        } else {
            UserDefaults.standard.removeObject(forKey: "logphoto.rawStage")
        }
        UserDefaults.standard.synchronize()
    }

    func shutter() {
        // Logフレームはアプリ側で純正と同じ音を鳴らす（マナーモードでは鳴らない）。
        // RAW はシステムが鳴らすのでここでは鳴らさない。
        if mode == .logFrame, shutterSoundEnabled {
            AudioServicesPlaySystemSound(1108)
        }
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
        guard let buffer else {
            dlog("capture", "Log フレーム撮影: フレームなし running=\(session.isRunning)")
            setStatus(L("status.noFrame"))
            return
        }

        let formatCode = fourCharCode(CVPixelBufferGetPixelFormatType(buffer))
        let isTIFF = outputFormat == .tiff
        let tiff16 = logFrame10Bit
        dlog("capture", "Log フレーム撮影 frame=\(formatCode) \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) 出力=\(isTIFF ? (tiff16 ? "TIFF 16bit" : "TIFF 8bit") : "JPEG 8bit") appleLog=\(appleLogActive)")
        // 撮った直後にアプリを離れても、変換と保存（16bit TIFF は 37MB）を終えられるようにする
        backgroundWorkStarted()

        // LUT なし & BGRA & フル画角: 画素値をそのまま書き出す（最速・無変換）
        if savedLUT == nil, !aspectFourThree,
           let data = imageDataFromPixelBuffer(buffer, isTIFF: isTIFF) {
            updateThumbnail(from: data)
            // BGRA のそのまま書き出しは 8bit
            savePhotoData(data, completion: logSaveMessage(isTIFF: isTIFF, tiff16: false, formatCode: formatCode),
                          onFinish: { [weak self] in self?.backgroundWorkFinished() })
            return
        }
        // それ以外（LUT適用 / TIFF / 非BGRA形式 / 4:3）は色管理なしの CI レンダリング。
        var image = CIImage(cvPixelBuffer: buffer)
        if aspectFourThree { image = cropToFourThree(image) }
        image = applyLUT(to: image, entry: savedLUT)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // TIFF は既定で 16bit で書き出し、10bit の Log フレーム（x422 など）の階調を落とさない。
        // 8bit を選んだときは 8bit TIFF（約半分の大きさ）
        let data = isTIFF
            ? rawContext.tiffRepresentation(of: image, format: tiff16 ? .RGBA16 : .RGBA8, colorSpace: colorSpace)
            : rawContext.jpegRepresentation(of: image, colorSpace: colorSpace)
        guard let data else {
            dlog("capture", "Log フレーム変換失敗 format=\(formatCode) tiff=\(isTIFF)")
            setStatus(L("status.convertFailed", formatCode))
            backgroundWorkFinished()
            return
        }
        updateThumbnail(from: data)
        savePhotoData(data, completion: logSaveMessage(isTIFF: isTIFF, tiff16: tiff16, formatCode: formatCode),
                      onFinish: { [weak self] in self?.backgroundWorkFinished() })
    }

    /// 保存メッセージに「本当に Apple Log だったか」を含める（検証用）。
    private func logSaveMessage(isTIFF: Bool, tiff16: Bool = true, formatCode: String) -> String {
        let kind = isTIFF ? L(tiff16 ? "status.logPhotoTiff" : "status.logPhotoTiff8") : L("status.logPhoto")
        let logState = appleLogActive ? "Apple Log" : L("status.logOff")
        return L("status.logSaved", kind, logState, formatCode)
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
            // 準備中（ProRAW の有効化待ちで Bayer だけ出ている間も含む）なら撮らずに待つ
            guard !self.rawSetupInProgress, let rawType = self.preferredRawPixelFormat() else {
                // レンズ切替直後などで RAW が準備中。画面は光っているので、ここで捨てると
                // 撮れたつもりで撮れていない。押した 1 枚を覚えておき、準備でき次第撮る。
                let until = Date().addingTimeInterval(5)
                self.pendingRawShutterUntil = until
                dlog("raw", "撮影要求したが RAW 準備中 → 準備でき次第撮影 setupInProgress=\(self.rawSetupInProgress) device=\(self.captureDevice?.localizedName ?? "nil") running=\(self.session.isRunning)")
                self.setStatus(L("status.rawWaiting"))
                // 準備中なら待つだけ（再構成すると準備がやり直しになって遅くなる）
                if !self.rawSetupInProgress { self.reconcileInput() }
                // 準備が終わらないまま黙って消えないよう、期限が来たら撮れなかったことを伝える
                self.sessionQueue.asyncAfter(deadline: .now() + 5.1) { [weak self] in
                    guard let self, self.pendingRawShutterUntil == until else { return }
                    self.pendingRawShutterUntil = nil
                    dlog("raw", "待っていたシャッターは RAW の準備が 5 秒で終わらず撮影せず")
                    self.setStatus(L("status.rawShotDropped"))
                }
                return
            }
            let isProRAW = AVCapturePhotoOutput.isAppleProRAWPixelFormat(rawType)
            // RAW の要件: デバイス倍率 1.0（念のためここでも保証）。切り出し倍率は別に覚える。
            if let device = self.captureDevice, device.videoZoomFactor != 1.0,
               (try? device.lockForConfiguration()) != nil {
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = 1.0
                device.unlockForConfiguration()
            }
            if let connection = self.photoOutput.connection(with: .video),
               connection.videoScaleAndCropFactor != 1.0 {
                connection.videoScaleAndCropFactor = 1.0
            }
            let dims = self.photoOutput.maxPhotoDimensions
            let fmt = self.fourCharCode(rawType)
            self.markRawStage("1 設定作成（\(fmt) \(dims.width)x\(dims.height) preset=\(self.rawUsesPhotoPreset ? "photo" : "input")）")
            dlog("raw", "撮影要求 kind=\(isProRAW ? "ProRAW" : "Bayer") fmt=\(fmt) dims=\(dims.width)x\(dims.height) device=\(self.captureDevice?.localizedName ?? "nil") zoom=\(self.captureDevice?.videoZoomFactor ?? 0) crop=\(self.previewCropFactor) preset=\(self.rawUsesPhotoPreset ? "photo" : "input") running=\(self.session.isRunning)")
            let settings = self.makeRawPhotoSettings(rawType: rawType)
            self.rawCropLock.lock()
            self.rawCropByCaptureID[settings.uniqueID] = self.previewCropFactor
            if isProRAW { self.rawRequestedDimsByCaptureID[settings.uniqueID] = dims }
            self.rawCropLock.unlock()
            self.markRawStage("2 capturePhoto 呼び出し（\(fmt) \(dims.width)x\(dims.height)）")
            self.backgroundWorkStarted() // 結果の受信と DNG 保存まで（didFinishProcessingPhoto で引き継ぐ）
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            self.markRawStage("3 撮影要求済み・結果待ち")
            self.setStatus(L("status.rawCapturing"))
        }
    }

    /// RAW(DNG) から Log変換画像（JPEG / TIFF）を作る。LUT 選択時は適用する。失敗時は nil。
    private func makeLogImageData(fromDNG data: Data, format: OutputFormat, crop: CGFloat) -> Data? {
        guard let rawFilter = CIRAWFilter(imageData: data, identifierHint: "dng") else { return nil }
        // 現像側のトーンカーブを全部切り、シーンリニアで受け取る（Log はこちらで掛ける）
        rawFilter.boostAmount = 0
        rawFilter.boostShadowAmount = 0
        rawFilter.localToneMapAmount = 0
        rawFilter.extendedDynamicRangeAmount = 2 // ハイライトの階調を 1.0 超として残す
        guard var image = rawFilter.outputImage else { return nil }

        // 撮影時の倍率に合わせてセンタートリミング（DNG 本体はフル画角のまま）
        if crop > 1.01 {
            image = centerCrop(image, factor: crop)
        }

        // Apple Log 符号化（式どおりの値になる）。統計はステータスに出して検証に使う。
        // 前面では GPU で計算する（48MP で CPU の数倍速い）。バックグラウンドでは GPU が使えないので
        // CPU で描く。GPU の途中でバックグラウンドに入って描けなかったときも CPU でやり直す。
        let sixteenBit = format == .tiff
        var encoded: AppleLog.Encoded? = nil
        if !appInBackground {
            encoded = AppleLog.encodeOnGPU(linearSRGB: image, context: rawConvertContext,
                                           sixteenBit: sixteenBit)
            lastRawLogPath = "GPU"
        }
        if encoded == nil {
            let background = appInBackground
            encoded = AppleLog.encodeOnCPU(linearSRGB: image,
                                           context: background ? rawConvertSoftwareContext : rawConvertContext,
                                           sixteenBit: sixteenBit)
            lastRawLogPath = background ? "CPU（バックグラウンド）" : "CPU"
        }
        guard let encoded else { return nil }
        lastRawLogStats = L("status.rawStats",
                                 encoded.black, encoded.median, encoded.white)
        // LUT を焼き込まないなら CGImage を直接書き出す（48MP で余計なコピーを作らない）
        guard let lut = savedLUT else {
            return AppleLog.fileData(from: encoded.image, tiff: sixteenBit)
        }
        let logImage = applyLUT(to: CIImage(cgImage: encoded.image), entry: lut)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let lutContext = appInBackground ? rawSoftwareContext : rawContext
        switch format {
        case .jpeg:
            return lutContext.jpegRepresentation(of: logImage, colorSpace: colorSpace)
        case .tiff:
            return lutContext.tiffRepresentation(of: logImage, format: .RGBA16,
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

    /// これ以上の大きさは一時ファイル経由で写真へ渡す。メモリのまま渡すと、48MP の TIFF（約 290MB）は
    /// PHPhotosErrorDomain 3301 で毎回のように保存に失敗していた（70MB の DNG・73MB の TIFF は成功）。
    private static let saveViaFileThreshold = 50_000_000

    /// onFinish: 保存が終わったら（失敗も含めて）呼ばれる。
    private func savePhotoData(_ data: Data,
                               uniformTypeIdentifier: String? = nil,
                               completion message: String,
                               onFinish: (() -> Void)? = nil) {
        let formatName = Self.imageFormatName(of: data)
        let sizeKB = data.count / 1000
        let fileURL = data.count >= Self.saveViaFileThreshold
            ? Self.writeTemporaryFile(data, formatName: formatName) : nil
        let payload: Data? = fileURL == nil ? data : nil // ファイルに書けたらメモリの方は手放す
        let via = fileURL == nil ? "memory" : "file"
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                dlog("save", "写真ライブラリの権限なし status=\(status.rawValue)")
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                self?.setStatus(L("status.photosDenied"))
                onFinish?()
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = uniformTypeIdentifier
                if let fileURL {
                    options.shouldMoveFile = true // コピーを作らず写真ライブラリへ移す
                    request.addResource(with: .photo, fileURL: fileURL, options: options)
                } else if let payload {
                    request.addResource(with: .photo, data: payload, options: options)
                }
            } completionHandler: { ok, error in
                // 移されずに残った一時ファイル（失敗時など）は消す
                if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
                if ok {
                    dlog("save", "保存OK format=\(formatName) size=\(sizeKB)KB via=\(via) type=\(uniformTypeIdentifier ?? "-")")
                } else {
                    let ns = error as NSError?
                    dlog("save", "保存失敗 format=\(formatName) size=\(sizeKB)KB via=\(via) domain=\(ns?.domain ?? "?") code=\(ns?.code ?? 0) \(error?.localizedDescription ?? "")")
                }
                self?.setStatus(ok ? message : L("status.saveFailed"))
                onFinish?()
            }
        }
    }

    /// 保存用の一時ファイルを書く。失敗したら nil（メモリから保存する）。
    private static func writeTemporaryFile(_ data: Data, formatName: String) -> URL? {
        let ext = ["JPEG": "jpg", "TIFF": "tif", "HEIC": "heic", "DNG": "dng"][formatName] ?? "dat"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: url)
            return url
        } catch {
            dlog("save", "一時ファイルへの書き込みに失敗（メモリから保存する） \(error.localizedDescription)")
            return nil
        }
    }

    /// 保存データの実際の形式をログ用に返す。ヘッダーを見るだけで画像全体はデコードしない。
    private static func imageFormatName(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return "?" }
        switch type {
        case "public.jpeg": return "JPEG"
        case "public.tiff": return "TIFF"
        case "public.heic": return "HEIC"
        case "com.adobe.raw-image", "com.adobe.dng": return "DNG"
        default: return type
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
        // レンズ切替直後の数フレームは色空間が整う前のことがあるので捨てる（前のフレームを保持）
        if CACurrentMediaTime() < ignoreFramesUntil { return }
        bufferLock.lock()
        latestBuffer = buffer
        bufferLock.unlock()
        // フレームサイズと画素形式の変化だけを公開する（タップAFの座標変換と検証表示に使う）
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        if w != lastFrameWidth || h != lastFrameHeight || pixelFormat != lastFramePixelFormat {
            lastFrameWidth = w
            lastFrameHeight = h
            lastFramePixelFormat = pixelFormat
            let code = fourCharCode(pixelFormat)
            dlog("session", "フレーム受信 \(code) \(w)x\(h)")
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
        markRawStage("4 結果受信")
        rawCropLock.lock()
        let crop = rawCropByCaptureID.removeValue(forKey: photo.resolvedSettings.uniqueID) ?? 1
        let requestedDims = rawRequestedDimsByCaptureID.removeValue(forKey: photo.resolvedSettings.uniqueID)
        rawCropLock.unlock()
        if let error {
            let ns = error as NSError
            dlog("raw", "撮影エラー domain=\(ns.domain) code=\(ns.code) \(error.localizedDescription) device=\(captureDevice?.localizedName ?? "nil") mode=\(mode.rawValue)")
            markRawStage(nil)
            setStatus(L("status.rawFailed", error.localizedDescription))
            backgroundWorkFinished()
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            dlog("raw", "結果受信したが fileDataRepresentation が nil isRaw=\(photo.isRawPhoto)")
            markRawStage(nil)
            setStatus(L("status.rawNoData"))
            backgroundWorkFinished()
            return
        }
        let rawDims = photo.resolvedSettings.rawPhotoDimensions
        dlog("raw", "結果受信 isRaw=\(photo.isRawPhoto) raw=\(rawDims.width)x\(rawDims.height) size=\(data.count / 1000)KB device=\(captureDevice?.localizedName ?? "nil")")
        if let requestedDims, Int(rawDims.width) * Int(rawDims.height) < Int(requestedDims.width) * Int(requestedDims.height) {
            dlog("raw", "⚠︎ ProRAW が指定より小さい（指定 \(requestedDims.width)x\(requestedDims.height) → 実際 \(rawDims.width)x\(rawDims.height)）")
        }
        if photo.isRawPhoto {
            // (1) DNG そのまま保存 (2) Log変換画像も保存
            // 撮影時にもらった処理枠は DNG 保存で返し、変換はもう 1 枠もらう（先に増やして 0 にしない）
            backgroundWorkStarted()
            markRawStage("5 DNG 保存（\(data.count / 1_000_000)MB）")
            savePhotoData(data,
                          uniformTypeIdentifier: "com.adobe.raw-image",
                          completion: L("status.dngSaved"),
                          onFinish: { [weak self] in self?.backgroundWorkFinished() })
            updateThumbnail(from: data)
            setStatus(L("status.dngConverting"))
            markRawStage("6 Log 変換開始（\(data.count / 1_000_000)MB）")
            // 変換は重い（CIRAWFilter）ので撮影コールバックから外し、1 回ずつ直列に行う
            let format = outputFormat
            rawConversionQueue.async { [weak self] in
                guard let self else { return }
                autoreleasepool {
                    let started = CACurrentMediaTime()
                    if let converted = self.makeLogImageData(fromDNG: data, format: format, crop: crop) {
                        dlog("raw", "Log 変換OK \(self.lastRawLogPath) \(String(format: "%.1f", CACurrentMediaTime() - started))秒 crop=\(String(format: "%.2f", crop)) size=\(converted.count / 1000)KB \(self.lastRawLogStats)")
                        self.markRawStage("7 変換画像の保存")
                        self.updateThumbnail(from: converted)
                        self.savePhotoData(converted, completion: (format == .tiff
                            ? L("status.logTiffSaved") : L("status.logJpegSaved"))
                            + "（\(self.lastRawLogStats)）",
                            onFinish: { self.backgroundWorkFinished() })
                    } else {
                        dlog("raw", "Log 変換に失敗（CIRAWFilter が nil か出力なし）")
                        self.setStatus(L("status.logConvertFailed"))
                        self.backgroundWorkFinished()
                    }
                    self.markRawStage(nil)
                }
            }
        } else {
            markRawStage(nil)
            updateThumbnail(from: data)
            savePhotoData(data, completion: L("status.photoSaved"),
                          onFinish: { [weak self] in self?.backgroundWorkFinished() })
        }
    }
}
