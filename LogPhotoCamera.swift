import AVFoundation
import CoreImage
import Photos
import UIKit

/// Log Photo 試作 v0（方式A）- iPhone 16 Pro / Apple Log（第1世代）向け
///
/// 仕組み:
/// 1. `.appleLog` を含む最大解像度のビデオフォーマットを選び activeColorSpace に設定
/// 2. AVCaptureVideoDataOutput の最新フレームを保持
/// 3. シャッター時にそのフレームを JPEG 化して写真ライブラリへ保存（見た目はフラットな Log）
///
/// 限界（v0）:
/// - 解像度はビデオフォーマット依存（4K想定で約8MP）
/// - 保存 JPEG のカラースペース表記は sRGB。Log のピクセル値をそのまま入れているため
///   見た目はフラットになるが、メタデータ上の Apple Log 表記までは保持しない（v1で対応予定）
/// - ここ（Linux）ではコンパイル検証不可。Xcode + 実機で要検証。
final class LogPhotoCamera: NSObject, ObservableObject {

    @Published var appleLogAvailable = false
    @Published var statusText = "準備中…"

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "logphoto.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()

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

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            setStatus("カメラが見つかりません")
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canAddInput(input) { session.addInput(input) }
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "logphoto.frames"))

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
            device.unlockForConfiguration()
        } catch {
            setStatus("カメラ設定に失敗しました")
        }
    }

    // MARK: - シャッター
    func captureLogPhoto() {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer else { setStatus("フレーム取得前です。少し待ってください"); return }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let data = ciContext.jpegRepresentation(of: ciImage,
                                                      colorSpace: colorSpace) else {
            setStatus("画像の変換に失敗しました")
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                self?.setStatus("写真への保存が許可されていません")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, _ in
                self?.setStatus(ok ? "Log写真を保存しました" : "保存に失敗しました")
            }
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }
}

// MARK: - フレーム受信
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
