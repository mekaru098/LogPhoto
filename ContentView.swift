import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var camera = LogPhotoCamera()
    @State private var flash = false
    @State private var showGrid = true
    @State private var pinchStartZoom: CGFloat? = nil
    // v1.3: 露出は UI 側 @State で持ち、onChange でカメラへ反映する
    // （カメラの @Published へ直接バインドして書き戻す形はクラッシュ対策で廃止）
    @State private var exposureEV: Double = 0
    @State private var zoomSliderValue: Double = 1.0
    @State private var showLUTImporter = false
    @State private var shutterLog: Double = -6

    private var lutSelection: Binding<String> {
        Binding(get: { camera.selectedLUTName },
                set: { camera.selectLUT($0) })
    }

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

                if camera.manualMode {
                    manualPanel
                }

                // マニュアル切替・形式・LUT
                HStack(spacing: 10) {
                    Button {
                        camera.setManualMode(!camera.manualMode)
                    } label: {
                        Text(camera.manualMode ? "マニュアル ON" : "マニュアル")
                            .font(.caption.bold())
                            .foregroundStyle(camera.manualMode ? .yellow : .white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.45), in: Capsule())
                    }

                    Picker("形式", selection: $camera.outputFormat) {
                        ForEach(LogPhotoCamera.OutputFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .colorScheme(.dark)
                    .frame(width: 128)

                    Picker("LUT", selection: lutSelection) {
                        ForEach(camera.lutNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)

                    Button {
                        showLUTImporter = true
                    } label: {
                        Text("LUT＋")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(.black.opacity(0.45), in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

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

                    Slider(value: $exposureEV, in: -2...2, step: 0.1)
                        .tint(.white)
                        .onChange(of: exposureEV) { _, newValue in
                            camera.applyExposureCompensation(newValue)
                        }

                    Text(String(format: "%+.1f EV", exposureEV))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                // 倍率ボタン（純正風: 0.5 / 1 / 2 / 5、ピンチでも変更可）
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
                .padding(.bottom, 8)

                // ズームスライダー（レンズ切替は仮想デバイスが自動で行う）
                HStack(spacing: 12) {
                    Text("ズーム")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Slider(value: $zoomSliderValue,
                           in: Double(camera.zoomRange.lowerBound)...Double(camera.zoomRange.upperBound))
                        .tint(.white)
                        .onChange(of: zoomSliderValue) { _, newValue in
                            camera.setZoom(CGFloat(newValue), ramp: false)
                        }
                        .onChange(of: camera.zoomFactor) { _, newValue in
                            if abs(zoomSliderValue - Double(newValue)) > 0.02 {
                                zoomSliderValue = Double(newValue)
                            }
                        }
                    Text(String(format: "%.1fx", camera.zoomFactor))
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 24)
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
        .onChange(of: camera.manualMode) { _, isOn in
            if isOn { shutterLog = log2(max(camera.shutterSeconds, 0.0001)) }
        }
        .fileImporter(isPresented: $showLUTImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
                      allowsMultipleSelection: false) { result in
            if let url = try? result.get().first {
                camera.importLUT(from: url)
            }
        }
    }

    // MARK: - マニュアルパネル
    private var manualPanel: some View {
        VStack(spacing: 8) {
            manualRow(label: "SS", value: shutterLabel(camera.shutterSeconds)) {
                Slider(value: $shutterLog,
                       in: log2(camera.shutterRange.lowerBound)...log2(camera.shutterRange.upperBound),
                       step: 0.05)
                    .tint(.white)
                    .onChange(of: shutterLog) { _, newValue in
                        camera.shutterSeconds = pow(2.0, newValue)
                        camera.updateManualExposure()
                    }
            }
            manualRow(label: "ISO", value: "\(Int(camera.isoValue))") {
                Slider(value: $camera.isoValue, in: camera.isoRange, step: 1)
                    .tint(.white)
                    .onChange(of: camera.isoValue) { _, _ in
                        camera.updateManualExposure()
                    }
            }
            manualRow(label: "焦点", value: focusLabel(camera.focusPosition)) {
                Slider(value: $camera.focusPosition, in: 0...1, step: 0.01)
                    .tint(.white)
                    .onChange(of: camera.focusPosition) { _, _ in
                        camera.updateManualFocus()
                    }
            }
            manualRow(label: "WB", value: "\(Int(camera.whiteBalanceKelvin))K") {
                Slider(value: $camera.whiteBalanceKelvin, in: 2500...8000, step: 50)
                    .tint(.white)
                    .onChange(of: camera.whiteBalanceKelvin) { _, _ in
                        camera.updateManualWhiteBalance()
                    }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func manualRow<Control: View>(label: String, value: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 30, alignment: .leading)
            control()
            Text(value)
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func shutterLabel(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1f\"", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    private func focusLabel(_ position: Double) -> String {
        if position < 0.05 { return "最短" }
        if position > 0.95 { return "無限遠" }
        return String(format: "%.2f", position)
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
