import CoreImage
import MetalKit
import SwiftUI

/// 自前レンダリングのプレビュー。
/// AVCaptureVideoPreviewLayer ではなく、ビデオフレームを Core Image で描くことで
/// 選択中の LUT と Log の見た目をそのままプレビューに反映する（保存結果と一致）。
struct CameraPreviewView: UIViewRepresentable {
    let camera: LogPhotoCamera

    func makeCoordinator() -> Coordinator {
        Coordinator(camera: camera)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.delegate = context.coordinator
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) { }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let camera: LogPhotoCamera
        private let commandQueue: MTLCommandQueue?
        private let ciContext: CIContext

        init(camera: LogPhotoCamera) {
            self.camera = camera
            if let device = MTLCreateSystemDefaultDevice() {
                commandQueue = device.makeCommandQueue()
                ciContext = CIContext(mtlDevice: device,
                                      options: [.workingColorSpace: NSNull(),
                                                .outputColorSpace: NSNull()])
            } else {
                commandQueue = nil
                ciContext = CIContext()
            }
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let image = camera.currentPreviewImage() else { return }
            let drawableSize = view.drawableSize
            guard drawableSize.width > 0, drawableSize.height > 0 else { return }

            // アスペクトフィル: はみ出す側をクロップして中央に配置
            let imageSize = image.extent.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            let scale = max(drawableSize.width / imageSize.width,
                            drawableSize.height / imageSize.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let tx = (drawableSize.width - scaled.extent.width) / 2 - scaled.extent.minX
            let ty = (drawableSize.height - scaled.extent.height) / 2 - scaled.extent.minY
            let placed = scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))

            ciContext.render(placed,
                             to: drawable.texture,
                             commandBuffer: commandBuffer,
                             bounds: CGRect(origin: .zero, size: drawableSize),
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
