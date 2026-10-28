import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// v1.12 の画面構成（純正カメラ寄り）:
/// - 倍率チップ（0.5 / 1x / 2 / 5）はシャッターの上に常時表示。チップ上を左右にドラッグ、
///   またはプレビューをピンチすると、その間だけスライダーが現れて 1.5 秒後に自動で消える。
/// - 倍率と AF 状態の読み出しは画面上部に常時表示。
/// - 形式 / 画角 / LUT / グリッド / マクロ / 露出 / マニュアル / 撮影モードなどの細かい設定は
///   右下の歯車ボタンで開閉するパネルに集約。
struct ContentView: View {
    @StateObject private var camera = LogPhotoCamera()
    @State private var flash = false
    @State private var showGrid = true
    @State private var showBadges = true
    @State private var showPanel = false
    @State private var pinchStartZoom: CGFloat? = nil
    // 露出は UI 側 @State で持ち、onChange でカメラへ反映する
    @State private var exposureEV: Double = 0
    // ズームスライダーは log2 スケールの UI 側の値で完結させる
    @State private var zoomLogUI: Double = 0
    @State private var isZoomEditing = false
    @State private var zoomSliderVisible = false
    @State private var zoomHideTask: Task<Void, Never>? = nil
    @State private var chipDragStartZoom: CGFloat? = nil
    @State private var focusReticle: CGPoint? = nil
    @State private var reticleScale: CGFloat = 1
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

            GeometryReader { geo in
                CameraPreviewView(camera: camera)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale in
                                if pinchStartZoom == nil {
                                    pinchStartZoom = camera.zoomFactor
                                    revealZoomSlider()
                                }
                                let target = (pinchStartZoom ?? 1.0) * scale
                                camera.setZoom(target, ramp: false)
                                zoomLogUI = log2(Double(max(target, 0.01)))
                                keepZoomSliderVisible()
                            }
                            .onEnded { _ in
                                pinchStartZoom = nil
                                scheduleZoomSliderHide()
                            }
                    )
                    .onTapGesture { location in
                        handleFocusTap(at: location, in: geo.size)
                    }
            }
            .ignoresSafeArea()

            if showGrid {
                RuleOfThirdsGrid()
                    .ignoresSafeArea()
            }

            // 4:3 画角のマスク（上下を暗くして撮影範囲を示す）
            if camera.aspectFourThree {
                GeometryReader { geo in
                    let visibleHeight = min(geo.size.width * 4 / 3, geo.size.height)
                    let barHeight = max((geo.size.height - visibleHeight) / 2, 0)
                    VStack(spacing: 0) {
                        Color.black.opacity(0.55).frame(height: barHeight)
                        Spacer()
                        Color.black.opacity(0.55).frame(height: barHeight)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            // タップAFの枠
            if let point = focusReticle {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .scaleEffect(reticleScale)
                    .position(point)
                    .allowsHitTesting(false)
            }

            if flash {
                Color.white.ignoresSafeArea()
            }

            VStack {
                topBar
                zoomReadout
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

                if showPanel {
                    settingsPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                zoomControl
                    .padding(.bottom, 14)

                bottomBar
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
        .onChange(of: camera.zoomFactor) { _, newValue in
            // 操作中でなければ、カメラ側の倍率にスライダー位置を合わせる
            if !isZoomEditing, chipDragStartZoom == nil, pinchStartZoom == nil {
                zoomLogUI = log2(Double(max(newValue, 0.01)))
            }
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

    // MARK: - 上部
    private var topBar: some View {
        HStack(spacing: 8) {
            if showBadges {
                Text(camera.appleLogAvailable ? "APPLE LOG" : "LOG 非対応")
                    .font(.caption2.bold())
                    .tracking(0.6)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                if camera.mode == .rawLog {
                    Text(camera.rawAvailable ? "RAW" : "RAW 準備中")
                        .font(.caption2.bold())
                        .tracking(0.6)
                        .foregroundStyle(camera.rawAvailable ? .white : .yellow)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                }
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
    }

    /// 倍率とAF状態の常時表示
    private var zoomReadout: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Text(zoomLabel(camera.zoomFactor))
                    .font(.caption.monospacedDigit().bold())
                Text("·")
                    .font(.caption)
                Image(systemName: "crosshair")
                    .font(.caption2)
                Text(camera.focusStatus)
                    .font(.caption.bold())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            Spacer()
        }
        .padding(.top, 6)
    }

    // MARK: - ズーム操作（チップ常時表示、操作中だけスライダー）
    private var zoomControl: some View {
        ZStack {
            zoomChips
                .opacity(zoomSliderVisible ? 0 : 1)
                .allowsHitTesting(!zoomSliderVisible)
            zoomSliderBar
                .opacity(zoomSliderVisible ? 1 : 0)
                .allowsHitTesting(zoomSliderVisible)
        }
        .frame(height: 44)
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.18), value: zoomSliderVisible)
    }

    /// 現在の倍率が属するプリセット（その倍率以下で最大のもの）。純正と同じ見せ方。
    private var activePreset: CGFloat? {
        let presets = camera.zoomPresets
        return presets.last(where: { $0 <= camera.zoomFactor + 0.001 }) ?? presets.first
    }

    private var zoomChips: some View {
        HStack(spacing: 6) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let isActive = activePreset == preset
                let showsLive = isActive && abs(camera.zoomFactor - preset) > 0.05
                Button {
                    camera.setZoom(preset, ramp: true, switchLensNow: true)
                    zoomLogUI = log2(Double(preset))
                } label: {
                    Text(showsLive ? zoomLabel(camera.zoomFactor) : presetLabel(preset))
                        .font(.system(size: isActive ? 12 : 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(isActive ? .yellow : .white)
                        .frame(minWidth: 34)
                        .frame(height: 34)
                        .padding(.horizontal, isActive ? 6 : 0)
                        .background(isActive ? Color.black.opacity(0.6) : Color.black.opacity(0.3),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.black.opacity(0.3), in: Capsule())
        // チップの上を左右にドラッグすると倍率が変わり、スライダーが出る（純正風）
        .highPriorityGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    if chipDragStartZoom == nil {
                        chipDragStartZoom = camera.zoomFactor
                        revealZoomSlider()
                    }
                    let start = chipDragStartZoom ?? 1
                    let target = start * CGFloat(pow(2.0, Double(value.translation.width) / 110))
                    camera.setZoom(target, ramp: false)
                    zoomLogUI = log2(Double(max(target, 0.01)))
                    keepZoomSliderVisible()
                }
                .onEnded { _ in
                    chipDragStartZoom = nil
                    scheduleZoomSliderHide()
                }
        )
    }

    private var zoomSliderBar: some View {
        let lo = log2(Double(max(camera.zoomRange.lowerBound, 0.01)))
        let hi = max(log2(Double(max(camera.zoomRange.upperBound, 0.01))), lo + 0.01)
        return HStack(spacing: 10) {
            Text(presetLabel(camera.zoomRange.lowerBound))
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(.white.opacity(0.8))
            Slider(value: $zoomLogUI, in: lo...hi,
                   onEditingChanged: { editing in
                       isZoomEditing = editing
                       if editing {
                           keepZoomSliderVisible()
                       } else {
                           scheduleZoomSliderHide()
                       }
                   })
                .tint(.yellow)
                .onChange(of: zoomLogUI) { _, newValue in
                    if isZoomEditing {
                        camera.setZoom(CGFloat(pow(2.0, newValue)), ramp: false)
                        keepZoomSliderVisible()
                    }
                }
            Text(zoomLabel(camera.zoomFactor))
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(.yellow)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(.black.opacity(0.45), in: Capsule())
    }

    private func revealZoomSlider() {
        zoomHideTask?.cancel()
        zoomHideTask = nil
        withAnimation(.easeInOut(duration: 0.18)) { zoomSliderVisible = true }
    }

    /// 操作が続いている間は消さない（消えるタイマーを取り消す）。
    private func keepZoomSliderVisible() {
        zoomHideTask?.cancel()
        zoomHideTask = nil
        if !zoomSliderVisible {
            withAnimation(.easeInOut(duration: 0.18)) { zoomSliderVisible = true }
        }
    }

    /// 最後の操作から 1.5 秒後にスライダーをしまう。
    private func scheduleZoomSliderHide(after seconds: Double = 1.5) {
        zoomHideTask?.cancel()
        zoomHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) { zoomSliderVisible = false }
        }
    }

    private func presetLabel(_ preset: CGFloat) -> String {
        if abs(preset - 1) < 0.001 { return "1x" }
        if abs(preset - preset.rounded()) < 0.001 { return String(format: "%.0f", preset) }
        return String(format: "%g", preset)
    }

    private func zoomLabel(_ zoom: CGFloat) -> String {
        if zoom >= 10 { return String(format: "%.0fx", zoom) }
        return String(format: "%.1fx", zoom)
    }

    // MARK: - 下部: サムネイル / シャッター / 設定
    private var bottomBar: some View {
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

            // 右下の設定ボタン: 細かい設定パネルの開閉
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showPanel.toggle() }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(showPanel ? .black : .white)
                    .frame(width: 46, height: 46)
                    .background(showPanel ? Color.white : Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11)
                        .stroke(.white.opacity(0.45), lineWidth: 1))
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 24)
    }

    // MARK: - 設定パネル（歯車で開閉）
    private var settingsPanel: some View {
        VStack(spacing: 12) {
            // マニュアル・形式・画角・LUT
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
                .frame(width: 108)

                Button {
                    camera.setAspectFourThree(!camera.aspectFourThree)
                } label: {
                    Text(camera.aspectFourThree ? "4:3" : "フル")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }

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

            // グリッド・マクロ・露出補正
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

                Button {
                    camera.setMacroMode(!camera.macroMode)
                } label: {
                    Text("マクロ")
                        .font(.caption.bold())
                        .foregroundStyle(camera.macroMode ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(camera.macroMode ? Color.white : Color.white.opacity(0.14),
                                    in: Capsule())
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
    }

    /// タップAF: プレビューの fill クロップを補正して画像上の正規化座標へ変換する。
    private func handleFocusTap(at location: CGPoint, in size: CGSize) {
        let frame = camera.previewFrameSize
        guard frame.width > 0, frame.height > 0, size.width > 0, size.height > 0 else { return }
        let imgAspect = frame.width / frame.height
        let viewAspect = size.width / size.height
        var u = location.x / size.width
        var v = location.y / size.height
        if imgAspect < viewAspect {
            let visible = imgAspect / viewAspect
            v = (1 - visible) / 2 + v * visible
        } else if imgAspect > viewAspect {
            let visible = viewAspect / imgAspect
            u = (1 - visible) / 2 + u * visible
        }
        camera.focusAt(previewPoint: CGPoint(x: u, y: v))
        focusReticle = location
        reticleScale = 1.3
        withAnimation(.easeOut(duration: 0.25)) { reticleScale = 1.0 }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            focusReticle = nil
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
