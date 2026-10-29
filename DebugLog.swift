import Foundation
import UIKit

/// 不具合調査用のファイルログ（Documents/logphoto-debug.log）。
/// 書き込みは専用キューで直列に行うので、どのスレッドからでも dlog() を呼べる。
/// 約 500KB を超えたら古い半分を捨てる。設定画面から共有シートで書き出せる。
final class DebugLog {
    static let shared = DebugLog()

    private let queue = DispatchQueue(label: "logphoto.debuglog")
    private let maxBytes = 500_000
    private let cleanExitKey = "logphoto.cleanExit"
    /// scripts/run_on_device.sh が起動時に渡す引数
    static let launchedByScriptArg = "--launched-by-script"
    private let url: URL
    // queue 上でのみ使う
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    var fileURL: URL { url }

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = dir.appendingPathComponent("logphoto-debug.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    /// アプリ起動時に 1 回呼ぶ。端末情報と、前回が正常終了だったかを記録する。
    func start() {
        let defaults = UserDefaults.standard
        let previousClean = defaults.object(forKey: cleanExitKey) as? Bool
        defaults.set(false, forKey: cleanExitKey)
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let os = UIDevice.current.systemVersion
        log("app", "===== launch v\(version) (\(build)) \(machine) iOS \(os) =====")
        if previousClean == false {
            // scripts/run_on_device.sh は起動中のアプリを止めて入れ直すので、その場合は異常終了扱いにしない
            if CommandLine.arguments.contains(Self.launchedByScriptArg) {
                log("app", "スクリプトから起動（前回はフォアグラウンド中に終了したが、入れ直しによる停止とみなす）")
            } else {
                log("app", "前回は正常に終了しなかった（フォアグラウンド中のクラッシュ/強制終了の可能性）")
            }
        }
    }

    /// scenePhase の変化を記録する。バックグラウンドに入った時点で「正常終了」とみなす。
    func scenePhaseChanged(_ name: String) {
        log("app", "scenePhase=\(name)")
        UserDefaults.standard.set(name != "active", forKey: cleanExitKey)
    }

    func log(_ category: String, _ message: String) {
        let now = Date()
        queue.async { [self] in
            let line = "\(formatter.string(from: now)) [\(category)] \(message)\n"
            append(line)
        }
    }

    /// ログを空にする。
    func clear() {
        queue.async { [self] in
            try? Data().write(to: url, options: .atomic)
        }
        log("app", "ログを消去")
    }

    /// 書き込み待ちを吐き出す（共有直前などに使う）。
    func flush() {
        queue.sync { }
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let size: Int
        do {
            let handle = try FileHandle(forWritingTo: url)
            // 末尾の位置 = 書く前の大きさ。ファイル属性を読む API（App Store の申告対象）を使わずに済ませる
            let end = try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
            size = Int(end) + data.count
        } catch {
            return
        }
        trimIfNeeded(size: size)
    }

    private func trimIfNeeded(size: Int) {
        guard size > maxBytes,
              let all = try? Data(contentsOf: url) else { return }
        var tail = Data(all.suffix(maxBytes / 2))
        if let newline = tail.firstIndex(of: 0x0A) {
            tail = Data(tail[tail.index(after: newline)...])
        }
        try? tail.write(to: url, options: .atomic)
    }
}

/// どこからでも呼べる短縮形。message は呼び出し側のスレッドで評価される。
func dlog(_ category: String, _ message: @autoclosure () -> String) {
    DebugLog.shared.log(category, message())
}
