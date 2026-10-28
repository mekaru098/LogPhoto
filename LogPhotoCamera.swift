import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// Log Photo v1.3 - iPhone 16 Pro / Apple Log（第1世代）向け
///
/// 2つの撮影モード:
/// - 方式A (.logFrame): Apple Log のビデオフレームをシャッター時に静止画保存（v0から継続）
/// - 方式B (.rawLog): Bayer RAW で撮影し、(1) DNG をそのまま保存、
///   (2) RAW を現像して Log カーブ（近似）で変換した JPEG も保存する
///
/// v1.1: 露出補正（-2EV〜+2EV）と三分割グリッドを追加。
/// v1.2: ズーム対応（トリプルカメラ、0.5/1/2/5 ボタン＋ピンチ）。
/// v1.3 の変更:
/// - 露出スライダーを触ると落ちる問題の対策: UI 側の @State から onChange で
///   反映する形に変え、カメラ側からの書き戻しをやめた。
/// - 方式Aの保存を再対策: BGRA 以外のフレーム形式では従来の色管理あり変換に
///   黙ってフォールバックして通常写真化していた。色管理なし（ワーキング
///   カラースペース null）の CI レンダリングに統一し、保存時のステータスに
///   フレーム形式（fmt）を表示して切り分けできるようにした。
/// - ズームスライダーを追加（仮想デバイスがレンズ切替を自動で行う）。
/// - 保存形式に TIFF を追加（方式Bは 16bit TIFF）。
/// - マニュアル撮影（SS / ISO / フォーカス / WB）を追加。
/// - LUT 対応: 内蔵LUT（近似変換・モノクロ）と .cube ファイルの読み込み。
///   選択した LUT は保存時に適用する。
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

    // v1.3: 保存形式と LUT
    @Published var outputFormat: OutputFormat = .jpeg
    @Published var lutNames: [String] = ["なし"]
    @Published var selectedLUTName: String = "なし"
    private let lutStore = LUTStore()
    private var lutEntries: [String: LUTStore.Entry] = [:]

    // v1.3: マニュアル撮影
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
    private var captureDevice: AVCaptureDevice?

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

        // ズーム用に仮想デバイス（トリプル→デュアル→広角の順で優先）。
        // 仮想デバイスで Log フォーマットが取れない場合は広角にフォールバックする。
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .back)
        var chosenDevice = discovery.devices.first
        if let candidate = chosenDevice,
           !candidate.formats.contains(where: { $0.supportedColorSpaces.contains(.appleLog) }),
           let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           wide.formats.contains(where: { $0.supportedColorSpaces.contains(.appleLog) }) {
            chosenDevice = wide
        }
        guard let device = chosenDevice,
              let input = try? AVCaptureDeviceInput(device: device) else {
            setStatus("カメラが見つかりません")
            return
        }
        captureDevice = device

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority // カスタムフォーマットを優先
        if session.canAddInput(input) { session.addInput(input) }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "logphoto.frames"))

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            let hasRaw = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
            DispatchQueue.main.async { self.rawAvailable = hasRaw }
        }

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90 // 縦向き
        }

        // Apple Log 対応フォーマットのうち最大解像度を選ぶ（16 Pro は Log 第1世代）
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
            // ズーム範囲とプリセット（純正風: 0.5 / 1 / 2 / 5、範囲外は除外）
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 15.0)
            let presets = [CGFloat(0.5), 1.0, 2.0, 5.0].filter {
                $0 >= device.minAvailableVideoZoomFactor - 0.001 && $0 <= maxZoom
            }
            let initialZoom = device.videoZoomFactor
            // マニュアル撮影の可動範囲
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
    }

    func selectLUT(_ name: String) {
        selectedLUTName = name
        UserDefaults.standard.set(name, forKey: "logphoto.selectedLUT")
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

    private var activeLUT: LUTStore.Entry? { lutEntries[selectedLUTName] }

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
    /// カメラの露出ターゲットをずらす。UI の @State から onChange 経由で呼ばれる。
    /// カメラ側から UI へ値を書き戻さない（v1.2 までの書き戻しがクラッシュの
    /// 原因候補だったため）。
    func applyExposureCompensation(_ ev: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let clamped = max(Double(device.minExposureTargetBias),
                              min(Double(device.maxExposureTargetBias), ev))
            device.setExposureTargetBias(Float(clamped), completionHandler: nil)
        }
    }

    // MARK: - マニュアル撮影
    func setManualMode(_ on: Bool) {
        manualMode = on
        if on {
            updateManualExposure()
            updateManualFocus()
            updateManualWhiteBalance()
            return
        }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
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
    }

    func updateManualExposure() {
        guard manualMode else { return }
        let seconds = shutterSeconds
        let iso = Float(isoValue)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            device.setExposureModeCustom(
                duration: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000_000),
                iso: iso, completionHandler: nil)
        }
    }

    func updateManualFocus() {
        guard manualMode else { return }
        let position = Float(focusPosition)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            device.setFocusModeLocked(lensPosition: position, completionHandler: nil)
        }
    }

    func updateManualWhiteBalance() {
        guard manualMode else { return }
        let kelvin = Float(whiteBalanceKelvin)
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: kelvin, tint: 0)
            var gains = device.deviceWhiteBalanceGains(for: values)
            let maxGain = device.maxWhiteBalanceGain
            gains.redGain = min(max(gains.redGain, 1), maxGain)
            gains.greenGain = min(max(gains.greenGain, 1), maxGain)
            gains.blueGain = min(max(gains.blueGain, 1), maxGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }

    // MARK: - ズーム
    /// 倍率ボタンは ramp で滑らかに、ピンチは ramp なしで即時に反映する。
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
            } catch {
                // ズーム設定に失敗しても撮影は継続できるので無視
            }
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
            savePhotoData(data, completion: isTIFF
                ? "Log写真（TIFF）を保存しました（fmt \(formatCode)）"
                : "Log写真を保存しました（fmt \(formatCode)）")
            return
        }
        // それ以外（LUT適用 / TIFF / 非BGRA形式）は色管理なしの CI レンダリング。
        // ワーキングカラースペース null なので Log の画素値は変換されない。
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
            setStatus("この設定では RAW 撮影できません")
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

// MARK: - フレーム受信（方式A用）
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
            // (1) DNG そのまま保存 (2) Log変換JPEGも保存
            savePhotoData(data,
                          uniformTypeIdentifier: "com.adobe.raw-image",
                          completion: "DNG（RAW）を保存しました")
            if let converted = makeLogImageData(fromDNG: data) {
                savePhotoData(converted, completion: outputFormat == .tiff
                    ? "Log変換TIFFも保存しました"
                    : "Log変換JPEGも保存しました")
            }
        } else {
            savePhotoData(data, completion: "写真を保存しました")
        }
    }
}
