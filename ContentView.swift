import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = LogPhotoCamera()
    @State private var flash = false
    @State private var showGrid = true
    @State private var pinchStartZoom: CGFloat? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            if pinchStartZoom == nil { pinchStartZoom = camera.zoomFactor }
                            camera.setZoom((pinchStartZoom ?? 1.0) * scale, ramp: false)
                        }
                        .onEnded { _ in pinchStartZoom = nil }
                )

            if showGrid {
                RuleOfThirdsGrid()
                    .ignoresSafeArea()
            }

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
                    .padding(.bottom, 12)

                // 構図グリッドと露出補正（Log撮影の露出決め用）
                HStack(spacing: 12) {
                    Button {
                        showGrid.toggle()
                    } label: {
                        Text(showGrid ? "グリッド ON" : "グリッド OFF")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.45), in: Capsule())
                    }

                    Text("露出")
                        .font(.caption.bold())
                        .foregroundStyle(.white)

                    Slider(value: Binding(
                        get: { camera.exposureCompensation },
                        set: { newValue in
                            camera.exposureCompensation = newValue
                            camera.applyExposureCompensation(newValue)
                        }
                    ), in: -2...2, step: 0.1)
                    .tint(.white)

                    Text(String(format: "%+.1f EV", camera.exposureCompensation))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                // 倍率切替（純正風: 0.5 / 1 / 2 / 5、ピンチでも変更可）
                HStack(spacing: 10) {
                    ForEach(camera.zoomPresets, id: \.self) { preset in
                        let isActive = abs(camera.zoomFactor - preset) < 0.06
                        Button {
                            camera.setZoom(preset)
                        } label: {
                            Text(preset == 1.0 ? "1x" : String(format: "%g", preset))
                                .font(.caption.bold())
                                .foregroundStyle(isActive ? .yellow : .white)
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                    }
                }
                .padding(.bottom, 12)

                // 撮影モード切替（方式A / 方式B）
                Picker("撮影モード", selection: $camera.mode) {
                    ForEach(LogPhotoCamera.CaptureMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .colorScheme(.dark)
                .padding(.horizontal, 40)
                .padding(.bottom, 16)

                // 下部: シャッター
                Button {
                    flash = true
                    withAnimation(.easeOut(duration: 0.25)) { flash = false }
                    camera.shutter()
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

private struct RuleOfThirdsGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                    path.move(to: CGPoint(x: width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: width * fraction, y: height))
                    path.move(to: CGPoint(x: 0, y: height * fraction))
                    path.addLine(to: CGPoint(x: width, y: height * fraction))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
