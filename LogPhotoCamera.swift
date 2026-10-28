import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// Log Photo v1.5 - iPhone 16 Pro / Apple Log（第1世代）向け
///
/// v1.5 の変更:
/// - マニュアルを押すとプレビューがちらつく/真っ暗になる問題を修正。
///   実カメラへ切り替える際に RAW 用フォーマット探索まで走っていたのが原因で、
///   探索は RAW+Log モードのときだけに限定した。あわせて探索方法を見直し
///   （写真解像度の大きい順に試し、失敗時は Log フォーマットへ復帰）。
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

    // 保存形式と LUT
    @Published var outputFormat: OutputFormat = .jpeg
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
    private var captureDevice: AVCaptureDevice?  // 現在の入力デバイス

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
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 15.0)
            let presets = [CGFloat(0.5), 1.0, 2.0, 5.0].filter {
                $0 >= device.minAvailableVideoZoomFactor - 0.001 && $0 <= maxZoom
            }
            let initialZoom = device.videoZoomFactor
            let rangeFormat = logFormat ?? device.activeFormat
            let isoLo = Double(rangeFormat.minISO)
            let isoHi = Double(rangeFormat.maxISO)
            let ssLo = rangeFormat.minExposureDuration.seconds
            let ssHi = min(rangeFormat.maxExposureDuration.seconds, 2.0)
            let currentISO = Double(device.iso)
            let currentSS = device.exposureDuration.seconds
            DispatchQueue.main.async {
                self.maxZoomFactor = maxZoom
                self.zoomPresets = presets.isEmpty ? [1.0] : presets
                self.zoomFactor = initialZoom
                self.zoomRange = device.minAvailableVideoZoomFactor...maxZoom
                if isoHi > isoLo { self.isoRange = isoLo...isoHi }
                if ssHi > ssLo { self.shutterRange = ssLo...ssHi }
                self.isoValue = min(max(currentISO, isoLo), isoHi)
                self.shutterSeconds = min(max(currentSS, ssLo), ssHi)
            }
            device.unlockForConfiguration()
        } catch {
            setStatus("カメラ設定に失敗しました")
        }
    }

    /// マニュアル / RAW が必要なときは実カメラ、それ以外は仮想デバイスへ。
    /// RAW 用フォーマット探索は RAW+Log モードのときだけ行う
    /// （マニュアルでも走らせるとフォーマット切替が多発してプレビューがちらつく）。
    private func reconcileInput(manual: Bool, mode: CaptureMode) {
        let wantsPhysical = manual || mode == .rawLog
        let target = wantsPhysical ? (physicalDevice ?? virtualDevice)
                                   : (virtualDevice ?? physicalDevice)
        guard let target, target != captureDevice else {
            if mode == .rawLog { ensureRawCapableFormat() }
            return
        }
        guard let newInput = try? AVCaptureDeviceInput(device: target) else { return }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if session.canAddInput(newInput) { session.addInput(newInput) }
        session.commitConfiguration()
        captureDevice = target
        applyVideoRotation()
        applyDeviceConfiguration(target)
        if mode == .rawLog { ensureRawCapableFormat() }
    }

    /// 実カメラで RAW が撮れるフォーマットを探して設定する（sessionQueue 上で呼ぶ）。
    /// 写真の最大解像度が大きい順に試し、見つからなければ Log フォーマットへ戻す。
    private func ensureRawCapableFormat() {
        guard let device = captureDevice else { return }
        if !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
            DispatchQueue.main.async { self.rawAvailable = true }
            return
        }
        func photoArea(_ format: AVCaptureDevice.Format) -> Int {
            format.supportedMaxPhotoDimensions
                .map { Int($0.width) * Int($0.height) }.max() ?? 0
        }
        let sorted = device.formats.sorted { a, b in
            let areaA = photoArea(a)
            let areaB = photoArea(b)
            if areaA != areaB { return areaA > areaB }
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) > Int(db.width) * Int(db.height)
        }
        var found = false
        do {
            try device.lockForConfiguration()
            for format in sorted {
                if format.supportedMaxPhotoDimensions.isEmpty { continue }
                device.activeFormat = format
                device.activeColorSpace = format.supportedColorSpaces.contains(.appleLog)
                    ? .appleLog
                    : (format.supportedColorSpaces.first ?? device.activeColorSpace)
                if !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty {
                    found = true
                    break
                }
            }
            device.unlockForConfiguration()
        } catch { }
        if found {
            DispatchQueue.main.async { self.rawAvailable = true }
            setStatus("RAW+Log の準備ができました")
        } else {
            // 見つからなければ Log フォーマットに復帰させる
            applyDeviceConfiguration(device)
            DispatchQueue.main.async { self.rawAvailable = false }
            setStatus("RAW 対応フォーマットが見つかりません")
        }
    }

    /// モード切替時に UI から呼ばれる。
    func modeChanged() {
        let currentMode = mode
        let manual = manualMode
        sessionQueue.async { [weak self] in
            self?.reconcileInput(manual: manual, mode: currentMode)
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
        let currentMode = mode
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
            self.reconcileInput(manual: on, mode: currentMode)
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
    func setZoom(_ factor: CGFloat, ramp: Bool = true) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let upper = max(self.maxZoomFactor, device.minAvailableVideoZoomFactor)
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), upper)
            do {
                try device.lockForConfiguration()
                if ramp {
                    device.ramp(toVideoZoomFactor: clamped, withRate: 12)
                } else {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = clamped
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch { }
        }
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

        // LUT なし & BGRA: 画素値をそのまま書き出す（最速・無変換）
        if activeLUT == nil, let data = imageDataFromPixelBuffer(buffer, isTIFF: isTIFF) {
            updateThumbnail(from: data)
            savePhotoData(data, completion: isTIFF
                ? "Log写真（TIFF）を保存しました（fmt \(formatCode)）"
                : "Log写真を保存しました（fmt \(formatCode)）")
            return
        }
        // それ以外（LUT適用 / TIFF / 非BGRA形式）は色管理なしの CI レンダリング。
        var image = CIImage(cvPixelBuffer: buffer)
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
