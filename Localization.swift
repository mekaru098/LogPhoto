import Foundation
import SwiftUI

/// アプリ内の言語切替（日本語 / English / 中文 / Italiano）。
/// 文言はすべて L("key") で引く。既定は端末の言語（対応外は English）。
final class AppLanguage: ObservableObject {
    enum Lang: String, CaseIterable, Identifiable {
        case ja, en, zh, it
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .ja: return "日本語"
            case .en: return "English"
            case .zh: return "中文（简体）"
            case .it: return "Italiano"
            }
        }
    }

    static let shared = AppLanguage()

    @Published var lang: Lang {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "logphoto.language") }
    }

    private init() {
        if let stored = UserDefaults.standard.string(forKey: "logphoto.language"),
           let l = Lang(rawValue: stored) {
            lang = l
        } else {
            let code = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if code.hasPrefix("ja") { lang = .ja }
            else if code.hasPrefix("zh") { lang = .zh }
            else if code.hasPrefix("it") { lang = .it }
            else { lang = .en }
        }
    }
}

/// 文言を現在の言語で返す。args があれば String(format:) で埋める。
func L(_ key: String, _ args: CVarArg...) -> String {
    let lang = AppLanguage.shared.lang
    let table = Strings.table[key]
    let text = table?[lang] ?? table?[.en] ?? key
    return args.isEmpty ? text : String(format: text, arguments: args)
}

enum Strings {
    typealias T = [AppLanguage.Lang: String]
    static let table: [String: T] = [
        // --- モード / 形式 ---
        "mode.logFrame": [.ja: "Logフレーム", .en: "Log frame", .zh: "Log 帧", .it: "Fotogramma Log"],
        "mode.rawLog": [.ja: "RAW+Log", .en: "RAW+Log", .zh: "RAW+Log", .it: "RAW+Log"],
        "lut.none": [.ja: "なし", .en: "None", .zh: "无", .it: "Nessuna"],
        // --- 上部 ---
        "badge.appleLog": [.ja: "APPLE LOG", .en: "APPLE LOG", .zh: "APPLE LOG", .it: "APPLE LOG"],
        "badge.logOff": [.ja: "⚠︎ LOG 無効", .en: "⚠︎ LOG OFF", .zh: "⚠︎ LOG 未启用", .it: "⚠︎ LOG OFF"],
        "badge.rawMode": [.ja: "RAW（Logは変換で付与）", .en: "RAW (Log via conversion)", .zh: "RAW（转换时加 Log）", .it: "RAW (Log in conversione)"],
        "badge.rawReady": [.ja: "RAW %.0fMP", .en: "RAW %.0fMP", .zh: "RAW %.0fMP", .it: "RAW %.0fMP"],
        "badge.proRawReady": [.ja: "ProRAW %.0fMP", .en: "ProRAW %.0fMP", .zh: "ProRAW %.0fMP", .it: "ProRAW %.0fMP"],
        "badge.rawPreparing": [.ja: "RAW 準備中", .en: "RAW preparing", .zh: "RAW 准备中", .it: "RAW in preparazione"],
        "badge.logUnsupported": [.ja: "LOG 非対応（%@）", .en: "LOG not supported (%@)", .zh: "不支持 LOG（%@）", .it: "LOG non supportato (%@)"],
        "settings.logExport": [.ja: "ログを書き出す", .en: "Export log", .zh: "导出日志", .it: "Esporta log"],
        "settings.logClear": [.ja: "ログを消去", .en: "Clear log", .zh: "清除日志", .it: "Cancella log"],
        "status.sessionStopped": [.ja: "カメラが停止しました。アプリを開き直してください", .en: "Camera stopped. Please reopen the app", .zh: "相机已停止，请重新打开应用", .it: "Fotocamera interrotta. Riapri l'app"],
        "crash.banner":[.ja: "前回 RAW 撮影中に終了 → 段階: %@", .en: "Last RAW capture ended abnormally → stage: %@", .zh: "上次 RAW 拍摄异常结束 → 阶段：%@", .it: "Ultimo scatto RAW interrotto → fase: %@"],
        // --- 読み出し / AF ---
        "af.auto": [.ja: "AF 自動", .en: "AF auto", .zh: "AF 自动", .it: "AF auto"],
        "af.tap": [.ja: "AF（タップ位置）", .en: "AF (tap)", .zh: "AF（点按处）", .it: "AF (tocco)"],
        "af.manual": [.ja: "MF", .en: "MF", .zh: "MF", .it: "MF"],
        "lens.ultraWide": [.ja: "超広角", .en: "Ultra wide", .zh: "超广角", .it: "Ultra grandangolo"],
        "lens.wide": [.ja: "広角", .en: "Wide", .zh: "广角", .it: "Grandangolo"],
        "lens.tele": [.ja: "望遠", .en: "Telephoto", .zh: "长焦", .it: "Teleobiettivo"],
        "lens.virtual": [.ja: "仮想", .en: "Virtual", .zh: "虚拟", .it: "Virtuale"],
        "lens.camera": [.ja: "カメラ", .en: "Camera", .zh: "相机", .it: "Fotocamera"],
        "lens.nearCrop": [.ja: "（近距離クロップ）", .en: " (near crop)", .zh: "（近距裁切）", .it: " (ritaglio vicino)"],
        "lens.equiv": [.ja: "%.1fx 相当", .en: "≈ %.1fx", .zh: "≈ %.1fx", .it: "≈ %.1fx"],
        "lens.tooCloseWarn": [.ja: "望遠の最短距離より近いです", .en: "Closer than the telephoto's minimum focus distance", .zh: "比长焦最近对焦距离更近", .it: "Più vicino della distanza minima del tele"],
        // --- 設定 ---
        "settings.title": [.ja: "設定", .en: "Settings", .zh: "设置", .it: "Impostazioni"],
        "settings.manual": [.ja: "マニュアル", .en: "Manual", .zh: "手动", .it: "Manuale"],
        "settings.format": [.ja: "形式", .en: "Format", .zh: "格式", .it: "Formato"],
        "settings.aspectFull": [.ja: "フル", .en: "Full", .zh: "全屏", .it: "Pieno"],
        "settings.lutAdd": [.ja: "LUT追加", .en: "Add LUT", .zh: "添加 LUT", .it: "Aggiungi LUT"],
        "manual.reset": [.ja: "初期値に戻す", .en: "Reset", .zh: "恢复默认", .it: "Ripristina"],
        "settings.macro": [.ja: "マクロ", .en: "Macro", .zh: "微距", .it: "Macro"],
        "settings.exposure": [.ja: "露出", .en: "EV", .zh: "曝光", .it: "EV"],
        "settings.resetAll": [.ja: "スライダーをすべて初期値に戻す（各行はダブルタップでも戻せる）", .en: "Reset all sliders (double-tap a row to reset it)", .zh: "重置所有滑块（双击某行可单独重置）", .it: "Ripristina tutti i cursori (doppio tocco su una riga)"],
        "settings.captureMode": [.ja: "撮影モード", .en: "Capture mode", .zh: "拍摄模式", .it: "Modalità"],
        "settings.lensAuto": [.ja: "オート", .en: "Auto", .zh: "自动", .it: "Auto"],
        "settings.lensManual": [.ja: "マニュアル", .en: "Manual", .zh: "手动", .it: "Manuale"],
        "settings.advanced": [.ja: "詳細設定", .en: "Advanced", .zh: "高级设置", .it: "Avanzate"],
        "settings.language": [.ja: "言語", .en: "Language", .zh: "语言", .it: "Lingua"],
        "settings.logUnavailable": [.ja: "この機種は Apple Log 非対応のため RAW+Log のみ", .en: "Apple Log is not supported on this device; RAW+Log only", .zh: "此机型不支持 Apple Log，仅可使用 RAW+Log", .it: "Apple Log non supportato su questo dispositivo; solo RAW+Log"],
        // --- マニュアル / プリセット ---
        "preset.label": [.ja: "プリセット", .en: "Presets", .zh: "预设", .it: "Preset"],
        "preset.hint": [.ja: "長押しで保存", .en: "Hold to save", .zh: "长按保存", .it: "Tieni premuto per salvare"],
        "preset.save": [.ja: "保存", .en: "Save", .zh: "保存", .it: "Salva"],
        "preset.overwrite": [.ja: "上書き保存", .en: "Overwrite", .zh: "覆盖保存", .it: "Sovrascrivi"],
        "preset.delete": [.ja: "削除（空にする）", .en: "Delete (clear slot)", .zh: "删除（清空）", .it: "Elimina (svuota)"],
        "common.cancel": [.ja: "キャンセル", .en: "Cancel", .zh: "取消", .it: "Annulla"],
        "preset.askSave": [.ja: "プリセット %d に現在の設定を保存しますか？", .en: "Save the current settings to preset %d?", .zh: "将当前设置保存到预设 %d？", .it: "Salvare le impostazioni nel preset %d?"],
        "preset.askOverwrite": [.ja: "プリセット %d は保存済みです。上書きしますか？", .en: "Preset %d already exists. Overwrite?", .zh: "预设 %d 已存在，是否覆盖？", .it: "Il preset %d esiste già. Sovrascrivere?"],
        "preset.saved": [.ja: "プリセット %d に保存しました", .en: "Saved to preset %d", .zh: "已保存到预设 %d", .it: "Salvato nel preset %d"],
        "preset.deleted": [.ja: "プリセット %d を削除しました", .en: "Preset %d deleted", .zh: "已删除预设 %d", .it: "Preset %d eliminato"],
        "preset.loaded": [.ja: "プリセット %d を呼び出しました", .en: "Preset %d loaded", .zh: "已载入预设 %d", .it: "Preset %d caricato"],
        "manual.focus": [.ja: "焦点", .en: "Focus", .zh: "对焦", .it: "Fuoco"],
        "manual.nearest": [.ja: "最短", .en: "Near", .zh: "最近", .it: "Min"],
        "manual.infinity": [.ja: "無限遠", .en: "∞", .zh: "无限远", .it: "∞"],
        // --- ステータス ---
        "status.preparing": [.ja: "準備中…", .en: "Preparing…", .zh: "准备中…", .it: "Preparazione…"],
        "status.needPermission": [.ja: "カメラの許可が必要です（設定アプリ）", .en: "Camera permission required (Settings app)", .zh: "需要相机权限（设置 App）", .it: "Serve il permesso fotocamera (app Impostazioni)"],
        "status.noCamera": [.ja: "カメラが見つかりません", .en: "No camera found", .zh: "未找到相机", .it: "Nessuna fotocamera trovata"],
        "status.configFailed": [.ja: "カメラ設定に失敗しました", .en: "Camera configuration failed", .zh: "相机配置失败", .it: "Configurazione fotocamera fallita"],
        "status.logReady": [.ja: "Apple Log で撮影できます（%@）", .en: "Apple Log ready (%@)", .zh: "可用 Apple Log 拍摄（%@）", .it: "Apple Log pronto (%@)"],
        "status.logUnsupportedLens": [.ja: "このレンズは Apple Log 非対応です（%@）", .en: "This lens does not support Apple Log (%@)", .zh: "此镜头不支持 Apple Log（%@）", .it: "Questo obiettivo non supporta Apple Log (%@)"],
        "status.rawPreparing": [.ja: "RAW を準備中…（%@）", .en: "Preparing RAW… (%@)", .zh: "正在准备 RAW…（%@）", .it: "Preparazione RAW… (%@)"],
        "status.teleFallback": [.ja: "望遠の最短距離より近いので広角のクロップに切り替えました", .en: "Too close for the telephoto; switched to the wide camera's crop", .zh: "距离小于长焦最近对焦距离，已切换为广角裁切", .it: "Troppo vicino per il tele; passato al ritaglio del grandangolo"],
        "status.rawReady": [.ja: "RAW+Log の準備ができました", .en: "RAW+Log ready", .zh: "RAW+Log 已就绪", .it: "RAW+Log pronto"],
        "status.rawUnavailable": [.ja: "この構成では RAW が使えませんでした", .en: "RAW is not available in this configuration", .zh: "当前配置无法使用 RAW", .it: "RAW non disponibile in questa configurazione"],
        "status.macro": [.ja: "マクロ（超広角）: 被写体に近づけます", .en: "Macro (ultra wide): you can get close", .zh: "微距（超广角）：可以靠近拍摄", .it: "Macro (ultra grandangolo): puoi avvicinarti"],
        "status.lutAdded": [.ja: "LUT「%@」を追加しました", .en: "LUT \"%@\" added", .zh: "已添加 LUT“%@”", .it: "LUT \"%@\" aggiunta"],
        "status.lutInvalid": [.ja: "その .cube は読み込めませんでした", .en: "That .cube could not be loaded", .zh: "无法读取该 .cube", .it: "Impossibile caricare quel .cube"],
        "status.noFrame": [.ja: "フレーム取得前です。少し待ってください", .en: "No frame yet. Please wait a moment", .zh: "尚未获取画面，请稍候", .it: "Nessun fotogramma ancora. Attendi"],
        "status.convertFailed": [.ja: "画像の変換に失敗しました（fmt %@）", .en: "Image conversion failed (fmt %@)", .zh: "图像转换失败（fmt %@）", .it: "Conversione immagine fallita (fmt %@)"],
        "status.logSaved": [.ja: "%@を保存しました（%@ / %@）", .en: "%@ saved (%@ / %@)", .zh: "已保存%@（%@ / %@）", .it: "%@ salvata (%@ / %@)"],
        "status.logPhoto": [.ja: "Log写真", .en: "Log photo", .zh: "Log 照片", .it: "Foto Log"],
        "status.logPhotoTiff": [.ja: "Log写真（TIFF 16bit）", .en: "Log photo (16-bit TIFF)", .zh: "Log 照片（16 位 TIFF）", .it: "Foto Log (TIFF 16 bit)"],
        "status.logPhotoTiff8": [.ja: "Log写真（TIFF 8bit）", .en: "Log photo (8-bit TIFF)", .zh: "Log 照片（8 位 TIFF）", .it: "Foto Log (TIFF 8 bit)"],
        "status.logOff": [.ja: "⚠︎ Log 無効", .en: "⚠︎ Log off", .zh: "⚠︎ Log 未启用", .it: "⚠︎ Log off"],
        "status.rawWaiting": [.ja: "RAW を準備中… 準備でき次第撮影します", .en: "Preparing RAW… will capture when ready", .zh: "正在准备 RAW…就绪后自动拍摄", .it: "Preparazione RAW… scatto appena pronto"],
        "status.rawShotDropped": [.ja: "RAW の準備ができず、撮影できませんでした", .en: "RAW was not ready. The photo was not taken", .zh: "RAW 未就绪，未能拍摄", .it: "RAW non pronto. Foto non scattata"],
        "status.rawCapturing": [.ja: "RAW撮影中…", .en: "Capturing RAW…", .zh: "正在拍摄 RAW…", .it: "Scatto RAW…"],
        "status.rawStats": [.ja: "黒 %.2f / 中央 %.2f / 白 %.2f", .en: "black %.2f / mid %.2f / white %.2f", .zh: "黑 %.2f / 中 %.2f / 白 %.2f", .it: "nero %.2f / medio %.2f / bianco %.2f"],
        "status.photosDenied": [.ja: "写真への保存が許可されていません", .en: "Saving to Photos is not allowed", .zh: "未允许保存到照片", .it: "Salvataggio in Foto non consentito"],
        "status.saveFailed": [.ja: "保存に失敗しました", .en: "Save failed", .zh: "保存失败", .it: "Salvataggio fallito"],
        "status.rawFailed": [.ja: "RAW撮影に失敗しました: %@", .en: "RAW capture failed: %@", .zh: "RAW 拍摄失败：%@", .it: "Scatto RAW fallito: %@"],
        "status.rawNoData": [.ja: "RAWデータが取得できませんでした", .en: "No RAW data received", .zh: "未获取到 RAW 数据", .it: "Nessun dato RAW ricevuto"],
        "status.dngSaved": [.ja: "DNG（RAW）を保存しました", .en: "DNG (RAW) saved", .zh: "已保存 DNG（RAW）", .it: "DNG (RAW) salvato"],
        "status.dngConverting": [.ja: "DNG を保存。Log 変換中…", .en: "DNG saved. Converting to Log…", .zh: "DNG 已保存，正在转换 Log…", .it: "DNG salvato. Conversione Log…"],
        "status.logTiffSaved": [.ja: "Log変換TIFFも保存しました", .en: "Log TIFF saved too", .zh: "Log 转换 TIFF 也已保存", .it: "Anche il TIFF Log è stato salvato"],
        "status.logJpegSaved": [.ja: "Log変換JPEGも保存しました", .en: "Log JPEG saved too", .zh: "Log 转换 JPEG 也已保存", .it: "Anche il JPEG Log è stato salvato"],
        "status.logConvertFailed": [.ja: "DNG は保存。Log 変換は失敗しました", .en: "DNG saved; Log conversion failed", .zh: "DNG 已保存，Log 转换失败", .it: "DNG salvato; conversione Log fallita"],
        "status.photoSaved": [.ja: "写真を保存しました", .en: "Photo saved", .zh: "已保存照片", .it: "Foto salvata"],
        "status.lastCrash": [.ja: "前回 RAW 撮影中に落ちました（段階: %@）", .en: "The app crashed during the last RAW capture (stage: %@)", .zh: "上次 RAW 拍摄时崩溃（阶段：%@）", .it: "L'app si è chiusa durante l'ultimo scatto RAW (fase: %@)"],
    ]
}

/// 端末の機種識別子（iPhone17,1 など）→ 製品名。
enum DeviceModel {
    static let identifier: String = {
        var sys = utsname()
        uname(&sys)
        let mirror = Mirror(reflecting: sys.machine)
        let id = mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(String(UnicodeScalar(UInt8(value))))
        }
        return id
    }()

    static let name: String = {
        let map: [String: String] = [
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd)",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone Air",
            "iPhone18,4": "iPhone 17",
            "x86_64": "Simulator", "arm64": "Simulator",
        ]
        if let n = map[identifier] { return n }
        return identifier.hasPrefix("iPhone") ? "iPhone (\(identifier))" : identifier
    }()
}
