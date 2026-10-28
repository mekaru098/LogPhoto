import CoreImage
import Foundation

/// .cube LUT の読み込み、CIColorCube 用データ生成、内蔵LUT、ユーザーLUTの保存管理。
final class LUTStore {

    struct Entry: Identifiable, Equatable {
        let name: String
        let dimension: Int
        let data: Data // CIColorCube 用 Float32 RGBA
        var id: String { name }
    }

    private(set) var userLUTs: [Entry] = []

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        userLUTs = files
            .filter { $0.pathExtension.lowercased() == "cube" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let parsed = CubeLUT.parse(fileAt: url) else { return nil }
                return Entry(name: url.deletingPathExtension().lastPathComponent,
                             dimension: parsed.dimension, data: parsed.data)
            }
    }

    /// .cube ファイルを取り込む。成功したらそのエントリを返す。
    @discardableResult
    func importLUT(from sourceURL: URL) -> Entry? {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        guard CubeLUT.parse(fileAt: sourceURL) != nil else { return nil }
        let dest = directory.appendingPathComponent(sourceURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            return nil
        }
        reload()
        return userLUTs.first { $0.name == dest.deletingPathExtension().lastPathComponent }
    }

    // MARK: - 内蔵LUT（コード生成・近似）

    static func builtinLogTo709() -> Entry {
        let data = CubeLUT.build(dimension: 32) { r, g, b in
            // 方式Bと同じ近似エンコードの逆変換でリニアに戻し、表示用ガンマをかける
            func dec(_ x: Float) -> Float { (powf(2, 8 * x) - 1) / 255 }
            func enc(_ x: Float) -> Float { powf(max(min(x, 1), 0), 1 / 2.2) }
            return (enc(dec(r)), enc(dec(g)), enc(dec(b)))
        }
        return Entry(name: "Log→709（近似・内蔵）", dimension: 32, data: data)
    }

    static func builtinMono() -> Entry {
        let data = CubeLUT.build(dimension: 16) { r, g, b in
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return (y, y, y)
        }
        return Entry(name: "モノクロ（内蔵）", dimension: 16, data: data)
    }
}

enum CubeLUT {

    /// .cube ファイルをパースして CIColorCube 用データを作る。
    static func parse(fileAt url: URL) -> (dimension: Int, data: Data)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text: text)
    }

    static func parse(text: String) -> (dimension: Int, data: Data)? {
        var dimension = 0
        var values: [Float] = []
        values.reserveCapacity(64 * 64 * 64 * 4)
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                dimension = Int(line.split(separator: " ").last ?? "") ?? 0
                continue
            }
            if line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN")
                || line.hasPrefix("LUT_1D") || line.hasPrefix("LUT_3D_INPUT_RANGE") {
                continue
            }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            guard parts.count == 3 else { continue }
            values.append(contentsOf: [parts[0], parts[1], parts[2], 1.0])
        }
        guard dimension >= 2, dimension <= 64,
              values.count == dimension * dimension * dimension * 4 else { return nil }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return (dimension, data)
    }

    /// 変換関数からキューブデータを生成する（Rが最速で変化する順序）。
    static func build(dimension: Int,
                      transform: (Float, Float, Float) -> (Float, Float, Float)) -> Data {
        var values: [Float] = []
        values.reserveCapacity(dimension * dimension * dimension * 4)
        let denom = Float(dimension - 1)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let out = transform(Float(r) / denom, Float(g) / denom, Float(b) / denom)
                    values.append(contentsOf: [out.0, out.1, out.2, 1.0])
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
