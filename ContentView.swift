import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var camera = LogPhotoCamera()
    @State private var flash = false
    @State private var showGrid = true
    @State private var showBadges = true
    @State private var pinchStartZoom: CGFloat? = nil
    // 露出は UI 側 @State で持ち、onChange でカメラへ反映する
    @State private var exposureEV: Double = 0
    @State private var zoomSliderValue: Double = 1.0
    @State private var showLUTImporter = false
    @State private var showLastPhoto = false
    @State private var shutterLog: Double = -6

    private var lutSelection: Binding<String> {
        Binding(get: { camera.selectedLUTName },
                set: { camera.selectLUT($0) })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(camera: camera)
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
                // 上部バー: バッジ（表示/非表示の切替つき）
                HStack(spacing: 8) {
                    if showBadges {
                        Text(camera.appleLogAvailable ? "APPLE LOG" : "LOG 非対応")
                            .font(.caption2.bold())
                            .tracking(0.6)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                    if showBadges {
                        Text("iPhone 16 Pro")
                            .font(.caption2)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showBadges.toggle() }
                    } label: {
                        Image(systemName: showBadges ? "eye" : "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)

                Spacer()

                Text(camera.statusText)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 10)

                if camera.manualMode {
                    manualPanel
                }

                // コントロールパネル
                VStack(spacing: 12) {
                    // マニュアル・形式・LUT
                    HStack(spacing: 10) {
                        Button {
                            camera.setManualMode(!camera.manualMode)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "slider.horizontal.3")
                                Text("マニュアル")
                            }
                            .font(.caption.bold())
                            .foregroundStyle(camera.manualMode ? .black : .white)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(camera.manualMode ? Color.white : Color.white.opacity(0.14),
                                        in: Capsule())
                        }

                        Picker("形式", selection: $camera.outputFormat) {
                            ForEach(LogPhotoCamera.OutputFormat.allCases) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        .colorScheme(.dark)
                        .frame(width: 118)

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
                            Image(systemName: "plus.circle.fill")
                                .font(.body)
                                .foregroundStyle(.white)
                        }
                    }

                    // グリッドと露出補正
                    HStack(spacing: 12) {
                        Button {
                            showGrid.toggle()
                        } label: {
                            Image(systemName: "grid")
                                .font(.body)
                                .foregroundStyle(showGrid ? .white : .white.opacity(0.4))
                                .frame(width: 34, height: 34)
                                .background(.white.opacity(0.12), in: Circle())
                        }

                        Text("露出")
                            .font(.caption.bold())
                            .foregroundStyle(.white)

                        Slider(value: $exposureEV, in: -2...2, step: 0.1)
                            .tint(.white)
                            .onChange(of: exposureEV) { _, newValue in
                                camera.applyExposureCompensation(newValue)
                            }

                        Text(String(format: "%+.1f", exposureEV))
                            .font(.caption.monospacedDigit().bold())
                            .foregroundStyle(.white)
                            .frame(width: 36, alignment: .trailing)
                    }

                    // 倍率ボタンとズームスライダー
                    HStack(spacing: 14) {
                        HStack(spacing: 7) {
                            ForEach(camera.zoomPresets, id: \.self) { preset in
                                let isActive = abs(camera.zoomFactor - preset) < 0.06
                                Button {
                                    camera.setZoom(preset)
                                } label: {
                                    Text(preset == 1.0 ? "1x" : String(format: "%g", preset))
                                        .font(.caption2.bold())
                                        .foregroundStyle(isActive ? .black : .white)
                                        .frame(width: 33, height: 33)
                                        .background(isActive ? Color.white : Color.white.opacity(0.14),
                                                    in: Circle())
                                }
                            }
                        }

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
                            .frame(width: 40, alignment: .trailing)
                    }

                    // 撮影モード切替（方式A / 方式B）
                    Picker("撮影モード", selection: $camera.mode) {
                        ForEach(LogPhotoCamera.CaptureMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .colorScheme(.dark)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24)
                    .stroke(.white.opacity(0.10), lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

                // 下部: サムネイル / シャッター
                HStack {
                    Button {
                        openGallery()
                    } label: {
                        Group {
                            if let thumbnail = camera.lastThumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11)
                            .stroke(.white.opacity(0.45), lineWidth: 1))
                    }

                    Spacer()

                    Button {
                        flash = true
                        withAnimation(.easeOut(duration: 0.25)) { flash = false }
                        camera.shutter()
                    } label: {
                        Circle()
                            .strokeBorder(.white, lineWidth: 3.5)
                            .frame(width: 72, height: 72)
                            .overlay(Circle().fill(.white).frame(width: 58, height: 58))
                    }

                    Spacer()

                    Color.clear.frame(width: 46, height: 46)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 24)
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
        .onChange(of: camera.shutterSeconds) { _, newValue in
            // デバイス切替などでカメラ側の値が更新されたらスライダー位置も合わせる
            if camera.manualMode {
                shutterLog = log2(max(newValue, 0.0001))
            }
        }
        .onChange(of: camera.mode) { _, _ in
            camera.modeChanged()
        }
        .fileImporter(isPresented: $showLUTImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
                      allowsMultipleSelection: false) { result in
            if let url = try? result.get().first {
                camera.importLUT(from: url)
            }
        }
        .fullScreenCover(isPresented: $showLastPhoto) {
            ZStack {
                Color.black.ignoresSafeArea()
                if let thumbnail = camera.lastThumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                }
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            showLastPhoto = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                        }
                    }
                    Spacer()
                }
                .padding()
            }
        }
    }

    /// サムネイルのタップで写真アプリを開く（開けない場合はアプリ内で表示）。
    private func openGallery() {
        guard camera.lastThumbnail != nil else { return }
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url) { opened in
                if !opened { showLastPhoto = true }
            }
        } else {
            showLastPhoto = true
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .stroke(.white.opacity(0.10), lineWidth: 1))
        .padding(.horizontal, 12)
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
