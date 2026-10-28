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

    /// Apple Log（BT.2020 原色）→ Rec.709 表示用。カメラの Log フレームにも、
    /// 方式Bで Apple Log 式で変換した画像にも同じように効く。
    static func builtinLogTo709() -> Entry {
        let data = CubeLUT.build(dimension: 48) { r, g, b in
            let lin2020 = (AppleLog.decode(r), AppleLog.decode(g), AppleLog.decode(b))
            // BT.2020 リニア → BT.709 リニア
            let r709 =  1.6605 * lin2020.0 - 0.5876 * lin2020.1 - 0.0728 * lin2020.2
            let g709 = -0.1246 * lin2020.0 + 1.1329 * lin2020.1 - 0.0083 * lin2020.2
            let b709 = -0.0182 * lin2020.0 - 0.1006 * lin2020.1 + 1.1187 * lin2020.2
            func display(_ x: Float) -> Float { powf(max(min(x, 1), 0), 1 / 2.2) }
            return (display(r709), display(g709), display(b709))
        }
        return Entry(name: "Apple Log→709（内蔵）", dimension: 48, data: data)
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

/// Apple Log の OETF（Apple Log Profile White Paper の式）と、Core Image での適用。
enum AppleLog {
    static let R0: Float = -0.05641088
    static let Rt: Float = 0.01
    static let c: Float = 47.28711236
    static let beta: Float = 0.00964052
    static let gamma: Float = 0.08550479
    static let delta: Float = 0.69336945
    /// 1.0 にエンコードされるリニア値（ハイライトの上限、約 12）
    static let maxLinear: Float = powf(2, (1 - delta) / gamma) - beta

    /// シーンリニア（18% グレー = 0.18）→ Apple Log 符号値（0...1）
    static func encode(_ x: Float) -> Float {
        if x >= Rt { return min(gamma * log2f(x + beta) + delta, 1) }
        if x >= R0 { return c * (x - R0) * (x - R0) }
        return 0
    }

    /// Apple Log 符号値 → シーンリニア
    static func decode(_ y: Float) -> Float {
        let yt = c * (Rt - R0) * (Rt - R0)
        if y >= yt { return powf(2, (y - delta) / gamma) - beta }
        return sqrtf(max(y, 0) / c) + R0
    }

    /// 符号化結果と、検証用の統計（黒 / 中央 / 白の符号値）。
    struct Encoded {
        let image: CGImage
        let black: Float
        let median: Float
        let white: Float
    }

    /// リニア sRGB の CIImage を CPU で BT.2020 原色の Apple Log 符号値にして CGImage にする。
    /// Core Image のフィルタ連鎖は色空間の扱いが読みにくいので、画素を float で取り出して
    /// 式どおりに計算する（12MP で float RGBA 192MB、autoreleasepool 内で使うこと）。
    /// sixteenBit = true なら 16bit RGB（TIFF 用）、false なら 8bit RGB（JPEG 用）。
    static func encodeOnCPU(linearSRGB image: CIImage, context: CIContext,
                            sixteenBit: Bool) -> Encoded? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        let count = width * height
        var floats = [Float](repeating: 0, count: count * 4)
        floats.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                           bounds: extent, format: .RGBAf, colorSpace: linearSpace)
        }
        // sRGB → BT.2020（リニア）
        let m: [Float] = [0.6274, 0.3293, 0.0433,
                          0.0691, 0.9195, 0.0114,
                          0.0164, 0.0880, 0.8956]
        let bytesPerPixel = sixteenBit ? 6 : 3
        var out = [UInt8](repeating: 0, count: count * bytesPerPixel)
        // 統計用: 輝度の符号値をサンプリング
        var samples: [Float] = []
        samples.reserveCapacity(count / 64 + 1)
        floats.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<count {
                    let r = src[i * 4], g = src[i * 4 + 1], b = src[i * 4 + 2]
                    let r2 = m[0] * r + m[1] * g + m[2] * b
                    let g2 = m[3] * r + m[4] * g + m[5] * b
                    let b2 = m[6] * r + m[7] * g + m[8] * b
                    let er = encode(r2), eg = encode(g2), eb = encode(b2)
                    if i % 64 == 0 { samples.append(0.2627 * er + 0.6780 * eg + 0.0593 * eb) }
                    if sixteenBit {
                        let o = i * 6
                        let vr = UInt16(er * 65535 + 0.5), vg = UInt16(eg * 65535 + 0.5), vb = UInt16(eb * 65535 + 0.5)
                        dst[o] = UInt8(vr >> 8); dst[o + 1] = UInt8(vr & 0xff)
                        dst[o + 2] = UInt8(vg >> 8); dst[o + 3] = UInt8(vg & 0xff)
                        dst[o + 4] = UInt8(vb >> 8); dst[o + 5] = UInt8(vb & 0xff)
                    } else {
                        let o = i * 3
                        dst[o] = UInt8(er * 255 + 0.5)
                        dst[o + 1] = UInt8(eg * 255 + 0.5)
                        dst[o + 2] = UInt8(eb * 255 + 0.5)
                    }
                }
            }
        }
        floats = []
        samples.sort()
        let black = samples.isEmpty ? 0 : samples[samples.count / 100]
        let median = samples.isEmpty ? 0 : samples[samples.count / 2]
        let white = samples.isEmpty ? 0 : samples[samples.count * 99 / 100]
        let data = Data(out)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height,
                               bitsPerComponent: sixteenBit ? 16 : 8,
                               bitsPerPixel: sixteenBit ? 48 : 24,
                               bytesPerRow: width * bytesPerPixel,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: sixteenBit
                                   ? (CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)
                                   : CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return Encoded(image: cg, black: black, median: median, white: white)
    }
}
