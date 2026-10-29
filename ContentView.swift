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
    @ObservedObject private var language = AppLanguage.shared
    @State private var flash = false
    @State private var showGrid = true
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
    @State private var showPresetDialog = false
    @State private var presetDialogIndex: Int? = nil
    @State private var presetDialogTitle = ""
    @State private var showAdvanced = false

    private var lutSelection: Binding<String> {
        Binding(get: { camera.selectedLUTName },
                set: { camera.selectLUT($0) })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // プレビュー: フル画角は全面、4:3 は純正と同じく上に寄せて下の黒い領域に操作系を置く
            GeometryReader { geo in
                let rect = previewRect(in: geo.size, safeTop: geo.safeAreaInsets.top)
                ZStack(alignment: .topLeading) {
                    CameraPreviewView(camera: camera)
                        .frame(width: rect.width, height: rect.height)
                        .overlay {
                            if showGrid { RuleOfThirdsGrid() }
                        }
                        .clipped()
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
                            handleFocusTap(at: location, in: rect.size)
                            focusReticle = CGPoint(x: location.x + rect.minX,
                                                   y: location.y + rect.minY)
                        }
                        .offset(x: rect.minX, y: rect.minY)

                    // タップAFの枠
                    if let point = focusReticle {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.yellow, lineWidth: 1.5)
                            .frame(width: 72, height: 72)
                            .scaleEffect(reticleScale)
                            .position(point)
                            .allowsHitTesting(false)
                    }
                }
            }
            .ignoresSafeArea()

            if flash {
                Color.white.ignoresSafeArea()
            }

            VStack {
                topBar
                zoomReadout
                if let stage = camera.lastCrashStage {
                    // 前回 RAW 撮影中に落ちた場合の切り分け表示（タップで消す）
                    Button {
                        camera.lastCrashStage = nil
                    } label: {
                        Text(L("crash.banner", stage))
                            .font(.caption2.bold())
                            .foregroundStyle(.black)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.yellow, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                Spacer()

                Text(camera.statusText)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 10)

                zoomControl
                    .padding(.bottom, 14)

                bottomBar
            }

            // 設定パネルとマニュアルバー: プレビューの上に透ける半透明パネルとして重ねる。
            // マニュアルバーは設定パネルの上に積み、設定を閉じるとその位置まで下にスライドする。
            // どちらも倍率チップとシャッター列は隠さない。
            if showPanel || camera.manualMode {
                VStack(spacing: 8) {
                    Spacer()
                    if camera.manualMode {
                        manualPanel
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if showPanel {
                        settingsSheet
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 168)
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showPanel)
        .animation(.easeInOut(duration: 0.22), value: camera.manualMode)
        .confirmationDialog(presetDialogTitle, isPresented: $showPresetDialog, titleVisibility: .visible) {
            if let i = presetDialogIndex {
                Button(camera.manualPresets[i] == nil ? L("preset.save") : L("preset.overwrite")) {
                    camera.saveManualPreset(to: i)
                }
                if camera.manualPresets[i] != nil {
                    Button(L("preset.delete"), role: .destructive) {
                        camera.deleteManualPreset(at: i)
                    }
                }
                Button(L("common.cancel"), role: .cancel) { }
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
            Text(camera.appleLogActive ? L("badge.appleLog")
                 : (camera.logUnsupportedDevice ? L("badge.logUnsupported", camera.deviceName)
                    : (camera.mode == .rawLog ? L("badge.rawMode") : L("badge.logOff"))))
                .font(.caption2.bold())
                .tracking(0.6)
                .foregroundStyle(camera.appleLogActive || camera.mode == .rawLog ? .white : .yellow)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            if camera.mode == .rawLog {
                Text(camera.rawAvailable
                     ? L(camera.rawIsProRAW ? "badge.proRawReady" : "badge.rawReady", camera.rawMegapixels)
                     : L("badge.rawPreparing"))
                    .font(.caption2.bold())
                    .tracking(0.6)
                    .foregroundStyle(camera.rawAvailable ? .white : .yellow)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            // マクロとレンズ切替方式は、メニューを開かずに切り替えられるよう上部に置く
            Button {
                camera.setMacroMode(!camera.macroMode)
            } label: {
                Text(L("settings.macro"))
                    .font(.caption2.bold())
                    .foregroundStyle(camera.macroMode ? .black : .white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(camera.macroMode ? Color.white : Color.black.opacity(0.35),
                                in: Capsule())
            }
            Button {
                camera.setLensSelectionMode(camera.lensSelectionMode == .auto ? .manual : .auto)
            } label: {
                Text(camera.lensSelectionMode == .auto ? L("settings.lensAuto") : L("settings.lensManual"))
                    .font(.caption2.bold())
                    .foregroundStyle(camera.lensSelectionMode == .manual ? .black : .white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(camera.lensSelectionMode == .manual ? Color.white : Color.black.opacity(0.35),
                                in: Capsule())
            }
            Text(camera.deviceName)
                .font(.caption2)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
            // シャッター音の ON/OFF
            Button {
                camera.setShutterSound(!camera.shutterSoundEnabled)
            } label: {
                Image(systemName: camera.shutterSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(camera.shutterSoundEnabled ? .white : .yellow)
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
                if camera.lensSelectionMode == .manual, let opt = selectedLensOption {
                    Text("\(opt.focalMM)mm · \(zoomLabel(camera.zoomFactor / opt.baseZoom))")
                        .font(.caption.monospacedDigit().bold())
                    Text("(" + L("lens.equiv", Double(camera.zoomFactor)) + ")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Text(zoomLabel(camera.zoomFactor))
                        .font(.caption.monospacedDigit().bold())
                }
                Text("·")
                    .font(.caption)
                Image(systemName: "crosshair")
                    .font(.caption2)
                Text(camera.focusStatus)
                    .font(.caption.bold())
                Text("·").font(.caption)
                Text(camera.activeLensName
                     + (camera.frameFormatCode.isEmpty ? "" : " " + camera.frameFormatCode))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.45), in: Capsule())
            Spacer()
        }
        .padding(.top, 6)
    }

    // MARK: - ズーム操作（チップ常時表示、操作中だけスライダー）
    /// チップは常時表示。スライダーはその上に別行で出る（ピンチ / チップのドラッグ /
    /// 選択中チップのタップで開き、しばらく触らないと閉じる）。
    private var zoomControl: some View {
        VStack(spacing: 10) {
            if zoomSliderVisible {
                zoomSliderBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if camera.lensSelectionMode == .manual {
                lensChips
            } else {
                zoomChips
            }
        }
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.18), value: zoomSliderVisible)
    }

    /// 現在の倍率が属するプリセット（その倍率以下で最大のもの）。純正と同じ見せ方。
    private var activePreset: CGFloat? {
        let presets = camera.zoomPresets
        return presets.last(where: { $0 <= camera.zoomFactor + 0.001 }) ?? presets.first
    }

    private var selectedLensOption: LogPhotoCamera.LensOption? {
        camera.lensOptions.first(where: { $0.id == camera.selectedLensID })
    }

    /// マニュアル方式のレンズ枠（13mm / 24mm / 48mm / 120mm …）。単眼機は 1 枠だけ。
    private var lensChips: some View {
        HStack(spacing: 6) {
            ForEach(camera.lensOptions) { opt in
                let isActive = camera.selectedLensID == opt.id
                Button {
                    if isActive {
                        if zoomSliderVisible {
                            zoomHideTask?.cancel()
                            withAnimation(.easeInOut(duration: 0.18)) { zoomSliderVisible = false }
                        } else {
                            revealZoomSlider()
                            scheduleZoomSliderHide(after: 4)
                        }
                        return
                    }
                    camera.selectLens(opt.id)
                    zoomLogUI = log2(Double(opt.baseZoom))
                } label: {
                    Text("\(opt.focalMM)mm")
                        .font(.system(size: isActive ? 12 : 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(isActive ? .yellow : .white)
                        .frame(minWidth: 44)
                        .frame(height: 34)
                        .padding(.horizontal, 6)
                        .background(isActive ? Color.black.opacity(0.6) : Color.black.opacity(0.3),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
    }

    private var zoomChips: some View {
        HStack(spacing: 6) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let isActive = activePreset == preset
                let showsLive = isActive && abs(camera.zoomFactor - preset) > 0.05
                Button {
                    if isActive, abs(camera.zoomFactor - preset) < 0.05 {
                        // 選択中のチップをもう一度タップ → スライダーの開閉
                        if zoomSliderVisible {
                            zoomHideTask?.cancel()
                            withAnimation(.easeInOut(duration: 0.18)) { zoomSliderVisible = false }
                        } else {
                            revealZoomSlider()
                            scheduleZoomSliderHide(after: 4)
                        }
                        return
                    }
                    camera.setZoom(preset, ramp: true, switchLensNow: true)
                    zoomLogUI = log2(Double(preset))
                    if zoomSliderVisible { scheduleZoomSliderHide(after: 4) }
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
        .padding(4)
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
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            let base = camera.lensSelectionMode == .manual ? (selectedLensOption?.baseZoom ?? 1) : 1
            camera.setZoom(base, ramp: true, switchLensNow: true)
            zoomLogUI = log2(Double(base))
        })
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
    private func scheduleZoomSliderHide(after seconds: Double = 2.5) {
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

    // MARK: - 設定シート（歯車で開閉。画面の下半分だけを使い、プレビューは見えたまま）
    private var settingsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("settings.title"))
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    showPanel = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)
            settingsPanel
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.12), lineWidth: 1))
        .fileImporter(isPresented: $showLUTImporter,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
                      allowsMultipleSelection: false) { result in
            if let url = try? result.get().first {
                camera.importLUT(from: url)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var settingsPanel: some View {
        VStack(spacing: 14) {
            // マニュアル・形式・画角
            HStack(spacing: 10) {
                Button {
                    camera.setManualMode(!camera.manualMode)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                        Text(L("settings.manual"))
                    }
                    .font(.caption.bold())
                    .foregroundStyle(camera.manualMode ? .black : .white)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(camera.manualMode ? Color.white : Color.white.opacity(0.14),
                                in: Capsule())
                }

                Picker(L("settings.format"), selection: $camera.outputFormat) {
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
                    Text(camera.aspectFourThree ? "4:3" : L("settings.aspectFull"))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }

                Spacer(minLength: 0)
            }

            // LUT: 選ぶボタン（押すと一覧が出る）と追加ボタン。選んだ LUT はプレビューと保存の両方に掛かる
            HStack(spacing: 10) {
                Menu {
                    Picker("LUT", selection: lutSelection) {
                        ForEach(camera.lutNames, id: \.self) { name in
                            Text(name == "なし" ? L("lut.none") : name).tag(name)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("LUT")
                            .font(.caption.bold())
                        Text(camera.selectedLUTName == "なし" ? L("lut.none") : camera.selectedLUTName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(camera.selectedLUTName == "なし" ? .white : .black)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(camera.selectedLUTName == "なし" ? Color.white.opacity(0.14) : Color.white,
                                in: Capsule())
                }

                Button {
                    showLUTImporter = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(L("settings.lutAdd"))
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.white.opacity(0.14), in: Capsule())
                }

                Spacer(minLength: 0)
            }

            // グリッド・露出補正（マクロは上部バーへ移した）
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

                Text(L("settings.exposure"))
                    .font(.caption.bold())
                    .foregroundStyle(.white)

                Slider(value: $exposureEV, in: camera.exposureRange, step: 0.1)
                    .tint(.white)
                    .onChange(of: exposureEV) { _, newValue in
                        camera.applyExposureCompensation(newValue)
                    }

                Text(String(format: "%+.1f", exposureEV))
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .frame(width: 40, alignment: .trailing)
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded { exposureEV = 0 })

            // すべて初期値に戻す
            Button {
                resetAllSliders()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(L("settings.resetAll"))
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
            }

            // 撮影モード切替（方式A / 方式B）と RAW の解像度
            HStack(spacing: 10) {
                if camera.logUnsupportedDevice {
                    Text(L("settings.logUnavailable"))
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker(L("settings.captureMode"), selection: $camera.mode) {
                        ForEach(LogPhotoCamera.CaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .colorScheme(.dark)
                }

                // RAW+Log は解像度（12MP / 48MP）、Log フレームは TIFF の階調（8bit / 10bit）を切り替える
                if camera.mode == .rawLog {
                    Button {
                        camera.setRawHighResolution(!camera.rawHighResolution)
                    } label: {
                        Text(camera.rawHighResolution ? "48MP" : "12MP")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(camera.rawHighResolution ? .black : .white)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(camera.rawHighResolution ? Color.white : Color.white.opacity(0.14),
                                        in: Capsule())
                    }
                } else {
                    Button {
                        camera.setLogFrame10Bit(!camera.logFrame10Bit)
                    } label: {
                        Text(camera.logFrame10Bit ? "10bit" : "8bit")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundStyle(camera.logFrame10Bit ? .black : .white)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(camera.logFrame10Bit ? Color.white : Color.white.opacity(0.14),
                                        in: Capsule())
                    }
                    // 階調の切替は TIFF の書き出しだけに効く（JPEG は常に 8bit）
                    .opacity(camera.logUnsupportedDevice || camera.outputFormat != .tiff ? 0.4 : 1)
                    .disabled(camera.logUnsupportedDevice || camera.outputFormat != .tiff)
                }
            }

            // 詳細設定（言語）
            DisclosureGroup(isExpanded: $showAdvanced) {
                HStack(spacing: 10) {
                    Text(L("settings.language"))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Picker(L("settings.language"), selection: $language.lang) {
                        ForEach(AppLanguage.Lang.allCases) { l in
                            Text(l.displayName).tag(l)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                    Spacer()
                }
                .padding(.top, 4)

                // 不具合調査用ログ（共有シートで書き出し → チャットに貼って原因を探せる）
                HStack(spacing: 14) {
                    ShareLink(item: DebugLog.shared.fileURL) {
                        Label(L("settings.logExport"), systemImage: "square.and.arrow.up")
                            .font(.caption.bold())
                    }
                    .simultaneousGesture(TapGesture().onEnded { DebugLog.shared.flush() })
                    Button {
                        DebugLog.shared.clear()
                    } label: {
                        Label(L("settings.logClear"), systemImage: "trash")
                            .font(.caption.bold())
                    }
                    Spacer()
                }
                .tint(.white)
                .padding(.top, 6)
            } label: {
                Text(L("settings.advanced"))
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.85))
            }
            .tint(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    /// プレビューの表示領域。4:3 のときは幅いっぱい・高さ 4/3 を上部バーの下に寄せ、
    /// 残りの下側（黒）に倍率チップとシャッターを置く（純正カメラと同じ配置）。
    private func previewRect(in size: CGSize, safeTop: CGFloat) -> CGRect {
        guard camera.aspectFourThree else { return CGRect(origin: .zero, size: size) }
        // 上の黒い領域（バッジ列＋読み出しの 2 行）の下から始め、下は操作系の分（約 150pt）を空ける。
        // 高さが足りなければ 4:3 を保ったまま幅を縮めて中央に置く
        let top = safeTop + 92
        let available = max(size.height - top - 150, 100)
        var height = min(size.width * 4 / 3, available)
        var width = size.width
        if height < size.width * 4 / 3 {
            width = height * 3 / 4
        } else {
            height = width * 4 / 3
        }
        return CGRect(x: (size.width - width) / 2, y: top, width: width, height: height)
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
        VStack(spacing: 2) {
            presetRow
            shutterRow
            isoRow
            focusRow
            whiteBalanceRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    /// プリセット 5 枠: タップで呼び出し、長押しで保存 / 上書き / 削除
    private var presetRow: some View {
        HStack(spacing: 6) {
            Text(L("preset.label"))
                .font(.caption2.bold())
                .foregroundStyle(.white.opacity(0.85))
            ForEach(0..<5, id: \.self) { i in
                PresetChip(number: i + 1,
                           saved: camera.manualPresets[i] != nil,
                           active: camera.activePresetIndex == i,
                           onTap: {
                               if camera.manualPresets[i] != nil {
                                   camera.loadManualPreset(at: i)
                               } else {
                                   openPresetDialog(i)
                               }
                           },
                           onLongPress: { openPresetDialog(i) })
            }
            Spacer()
            Text(L("preset.hint"))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(-1) // 幅が足りないときはヒントの方を縮める
            // SS / ISO / 焦点 / WB のスライダーを初期値へ（各行のダブルタップと同じ値）
            Button {
                resetManualSliders()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(L("manual.reset"))
                }
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.14), in: Capsule())
            }
        }
        .padding(.bottom, 2)
    }

    private var shutterRange: ClosedRange<Double> {
        let lo = log2(camera.shutterRange.lowerBound)
        let hi = log2(camera.shutterRange.upperBound)
        return lo...max(hi, lo + 0.01)
    }

    private var shutterRow: some View {
        manualRow(label: "SS", value: shutterLabel(camera.shutterSeconds),
                  onReset: { shutterLog = log2(1.0 / 60) }) {
            Slider(value: $shutterLog, in: shutterRange, step: 0.05)
                .tint(.white)
                .onChange(of: shutterLog) { _, newValue in
                    camera.shutterSeconds = pow(2.0, newValue)
                    camera.updateManualExposure()
                    camera.manualValueEdited()
                }
        }
    }

    private var isoRow: some View {
        manualRow(label: "ISO", value: "\(Int(camera.isoValue))",
                  onReset: { camera.isoValue = defaultISO }) {
            Slider(value: $camera.isoValue, in: camera.isoRange, step: 1)
                .tint(.white)
                .onChange(of: camera.isoValue) { _, _ in
                    camera.updateManualExposure()
                    camera.manualValueEdited()
                }
        }
    }

    private var focusRow: some View {
        manualRow(label: L("manual.focus"), value: focusLabel(camera.focusPosition),
                  onReset: { camera.focusPosition = 0.5 }) {
            Slider(value: $camera.focusPosition, in: 0...1, step: 0.01)
                .tint(.white)
                .onChange(of: camera.focusPosition) { _, _ in
                    camera.updateManualFocus()
                    camera.manualValueEdited()
                }
        }
    }

    private var whiteBalanceRow: some View {
        manualRow(label: "WB", value: "\(Int(camera.whiteBalanceKelvin))K",
                  onReset: { camera.whiteBalanceKelvin = 5200 }) {
            Slider(value: $camera.whiteBalanceKelvin, in: 2500...8000, step: 50)
                .tint(.white)
                .onChange(of: camera.whiteBalanceKelvin) { _, _ in
                    camera.updateManualWhiteBalance()
                    camera.manualValueEdited()
                }
        }
    }

    private var defaultISO: Double {
        min(max(100, camera.isoRange.lowerBound), camera.isoRange.upperBound)
    }

    private func openPresetDialog(_ index: Int) {
        presetDialogIndex = index
        presetDialogTitle = camera.manualPresets[index] == nil
            ? L("preset.askSave", index + 1)
            : L("preset.askOverwrite", index + 1)
        showPresetDialog = true
    }

    /// 露出 / ズーム / SS / ISO / 焦点 / WB をすべて初期値へ。
    private func resetAllSliders() {
        exposureEV = 0
        camera.setZoom(1.0, ramp: true, switchLensNow: true)
        zoomLogUI = 0
        resetManualSliders()
    }

    /// マニュアルの SS / ISO / 焦点 / WB だけを初期値へ（ズームと露出補正はそのまま）。
    private func resetManualSliders() {
        shutterLog = log2(1.0 / 60)
        camera.isoValue = defaultISO
        camera.focusPosition = 0.5
        camera.whiteBalanceKelvin = 5200
        camera.manualValueEdited()
    }

    private func manualRow<Control: View>(label: String, value: String,
                                          onReset: @escaping () -> Void,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(width: 26, alignment: .leading)
            control()
                .controlSize(.mini)
            Text(value)
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 50, alignment: .trailing)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
    }

    private func shutterLabel(_ seconds: Double) -> String {
        if seconds >= 1 { return String(format: "%.1f\"", seconds) }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    private func focusLabel(_ position: Double) -> String {
        if position < 0.05 { return L("manual.nearest") }
        if position > 0.95 { return L("manual.infinity") }
        return String(format: "%.2f", position)
    }
}

/// マニュアルプリセットの 1 枠。
private struct PresetChip: View {
    let number: Int
    let saved: Bool
    let active: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    private var textColor: Color {
        if active { return .black }
        return saved ? .white : .white.opacity(0.4)
    }

    private var fillColor: Color {
        if active { return .yellow }
        return saved ? Color.white.opacity(0.22) : Color.white.opacity(0.08)
    }

    var body: some View {
        Text("\(number)")
            .font(.caption.bold().monospacedDigit())
            .foregroundStyle(textColor)
            .frame(width: 30, height: 26)
            .background(fillColor, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(.white.opacity(saved ? 0.5 : 0.18), lineWidth: 1))
            .onTapGesture { onTap() }
            .onLongPressGesture(minimumDuration: 0.45) { onLongPress() }
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
            // 中央の縦線（既定で表示）
            Path { path in
                path.move(to: CGPoint(x: geometry.size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height))
            }
            .stroke(.white.opacity(0.6), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

#Preview {
    ContentView()
}
