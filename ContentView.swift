import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = LogPhotoCamera()
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            if flash {
                Color.white.ignoresSafeArea()
            }

            VStack {
                // 上部: ステータス
                HStack {
                    Text(camera.appleLogAvailable ? "APPLE LOG" : "LOG 非対応フォーマット")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Text("iPhone 16 Pro")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()

                Spacer()

                Text(camera.statusText)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 16)

                // 下部: シャッター
                Button {
                    flash = true
                    withAnimation(.easeOut(duration: 0.25)) { flash = false }
                    camera.captureLogPhoto()
                } label: {
                    Circle()
                        .strokeBorder(.white, lineWidth: 4)
                        .frame(width: 74, height: 74)
                        .overlay(Circle().fill(.white).frame(width: 60, height: 60))
                }
                .padding(.bottom, 28)
            }
        }
        .task {
            await camera.requestAndStart()
        }
        .onDisappear {
            camera.stop()
        }
    }
}

#Preview {
    ContentView()
}
