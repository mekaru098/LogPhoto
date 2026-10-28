import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// Log Photo v1.2 - iPhone 16 Pro / Apple Log（第1世代）向け
///
/// 2つの撮影モード:
/// - 方式A (.logFrame): Apple Log のビデオフレームをシャッター時に静止画保存（v0から継続）
/// - 方式B (.rawLog): Bayer RAW で撮影し、(1) DNG をそのまま保存、
///   (2) RAW を現像して Log カーブ（近似）で変換した JPEG も保存する
///
/// v1.1 では撮影時の露出補正（-2EV〜+2EV）を追加。
/// v1.2 の変更:
/// - ズーム対応: トリプルカメラ（仮想デバイス）を使い、0.5/1/2/5 の倍率ボタンと
///   ピンチズームでレンズ切替＋ズームができるようにした。
/// - 方式Aの保存を修正: v1.1 までは Core Image の色管理変換経由で sRGB 化していたため
///   Log の見た目が通常写真に寄ってしまっていた。v1.2 ではフレームの画素値を
///   変換せずそのまま JPEG 化し、Log エンコードを保持する。
/// 方式Bの Log 変換は Apple Log の厳密な OETF ではなく近似カーブ。
final class LogPhotoCamera: NSObject, ObservableObject {

    enum CaptureMode: String, CaseIterable, Identifiable {
        case logFrame = "Logフレーム"
        case rawLog = "RAW+Log"
        var id: String { rawValue }
    }

    @Published var appleLogAvailable = false
    @Published var rawAvailable = false
    @Published var statusText = "準備中…"
    @Published var mode: CaptureMode = .logFrame
    @Published var exposureCompensation: Double = 0
    @Published var zoomFactor: CGFloat = 1.0
    @Published var zoomPresets: [CGFloat] = [1.0]
    private var maxZoomFactor: CGFloat = 1.0

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "logphoto.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let ciContext = CIContext()
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
            DispatchQueue.main.async {
                self.maxZoomFactor = maxZoom
                self.zoomPresets = presets.isEmpty ? [1.0] : presets
                self.zoomFactor = initialZoom
            }
            device.unlockForConfiguration()
        } catch {
            setStatus("カメラ設定に失敗しました")
        }
    }

    // MARK: - 露出補正
    /// カメラの露出ターゲットをずらす。Log撮影時の露出決めに使う想定。
    func applyExposureCompensation(_ ev: Double) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            let clamped = max(Double(device.minExposureTargetBias),
                              min(Double(device.maxExposureTargetBias), ev))
            device.setExposureTargetBias(Float(clamped), completionHandler: nil)
            if abs(self.exposureCompensation - clamped) > 0.001 {
                DispatchQueue.main.async { self.exposureCompensation = clamped }
            }
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

        // Log エンコードされた画素値を色管理変換で化けさせないよう、
        // バッファをそのまま JPEG 化する（プロファイルは sRGB を付ける）。
        if let data = jpegDataFromPixelBuffer(buffer) {
            savePhotoData(data, completion: "Log写真を保存しました")
            return
        }
        // フォールバック: 従来の Core Image 経路
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let data = ciContext.jpegRepresentation(of: ciImage,
                                                      colorSpace: colorSpace) else {
            setStatus("画像の変換に失敗しました")
            return
        }
        savePhotoData(data, completion: "Log写真を保存しました")
    }

    /// BGRA ピクセルバッファの画素値を変換せずに JPEG データ化する。
    private func jpegDataFromPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> Data? {
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
        guard let destination = CGImageDestinationCreateWithData(
            out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage,
            [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
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

    /// RAW(DNG) から Log変換JPEG を作る。失敗時は nil。
    private func makeLogJPEG(fromDNG data: Data) -> Data? {
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

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace)
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
            if let jpeg = makeLogJPEG(fromDNG: data) {
                savePhotoData(jpeg, completion: "Log変換JPEGも保存しました")
            }
        } else {
            savePhotoData(data, completion: "写真を保存しました")
        }
    }
}
