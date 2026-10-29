import Accelerate
import CoreImage
import Foundation
import ImageIO

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
        return Entry(name: "Apple Log→709", dimension: 48, data: data)
    }

    static func builtinMono() -> Entry {
        let data = CubeLUT.build(dimension: 16) { r, g, b in
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return (y, y, y)
        }
        return Entry(name: "Mono", dimension: 16, data: data)
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
    /// 式どおりに計算する。48MP でも落ちないよう、横帯（ストリップ）ごとに取り出して処理する
    /// （float の作業バッファは 1 帯分だけ。出力は 8bit RGB で 48MP ≈ 144MB、16bit で 288MB）。
    /// sixteenBit = true なら 16bit RGB（TIFF 用）、false なら 8bit RGB（JPEG 用）。
    static func encodeOnCPU(linearSRGB image: CIImage, context: CIContext,
                            sixteenBit: Bool) -> Encoded? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB) else { return nil }
        let bytesPerPixel = sixteenBit ? 6 : 3
        let outRowBytes = width * bytesPerPixel
        var out = [UInt8](repeating: 0, count: outRowBytes * height)
        // sRGB → BT.2020（リニア）
        let m: [Float] = [0.6274, 0.3293, 0.0433,
                          0.0691, 0.9195, 0.0114,
                          0.0164, 0.0880, 0.8956]
        let stripRows = max(1, min(height, (64 * 1024 * 1024) / (width * 16))) // 1 帯 ≈ 64MB
        var strip = [Float](repeating: 0, count: width * stripRows * 4)
        var samples: [Float] = []
        samples.reserveCapacity(width * height / 256 + 1)
        var y0 = 0
        while y0 < height {
            let rows = min(stripRows, height - y0)
            // CIImage の座標は下が原点。出力は上から詰めるので帯の位置を反転して取り出す。
            let bounds = CGRect(x: extent.minX,
                                y: extent.maxY - CGFloat(y0 + rows),
                                width: CGFloat(width), height: CGFloat(rows))
            strip.withUnsafeMutableBytes { raw in
                context.render(image, toBitmap: raw.baseAddress!, rowBytes: width * 16,
                               bounds: bounds, format: .RGBAf, colorSpace: linearSpace)
            }
            strip.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    let count = width * rows
                    for i in 0..<count {
                        let r = src[i * 4], g = src[i * 4 + 1], b = src[i * 4 + 2]
                        let r2 = m[0] * r + m[1] * g + m[2] * b
                        let g2 = m[3] * r + m[4] * g + m[5] * b
                        let b2 = m[6] * r + m[7] * g + m[8] * b
                        let er = encode(r2), eg = encode(g2), eb = encode(b2)
                        if i % 256 == 0 { samples.append(0.2627 * er + 0.6780 * eg + 0.0593 * eb) }
                        let o = (y0 * width + i) * bytesPerPixel
                        if sixteenBit {
                            let vr = UInt16(er * 65535 + 0.5), vg = UInt16(eg * 65535 + 0.5), vb = UInt16(eb * 65535 + 0.5)
                            dst[o] = UInt8(vr >> 8); dst[o + 1] = UInt8(vr & 0xff)
                            dst[o + 2] = UInt8(vg >> 8); dst[o + 3] = UInt8(vg & 0xff)
                            dst[o + 4] = UInt8(vb >> 8); dst[o + 5] = UInt8(vb & 0xff)
                        } else {
                            dst[o] = UInt8(er * 255 + 0.5)
                            dst[o + 1] = UInt8(eg * 255 + 0.5)
                            dst[o + 2] = UInt8(eb * 255 + 0.5)
                        }
                    }
                }
            }
            y0 += rows
        }
        strip = []
        samples.sort()
        let black = samples.isEmpty ? 0 : samples[samples.count / 100]
        let median = samples.isEmpty ? 0 : samples[samples.count / 2]
        let white = samples.isEmpty ? 0 : samples[samples.count * 99 / 100]
        let data = Data(out)
        out = []
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height,
                               bitsPerComponent: sixteenBit ? 16 : 8,
                               bitsPerPixel: sixteenBit ? 48 : 24,
                               bytesPerRow: outRowBytes,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: sixteenBit
                                   ? (CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Big.rawValue)
                                   : CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return Encoded(image: cg, black: black, median: median, white: white)
    }

    // MARK: - GPU 版（Core Image の Metal カーネル）
    /// encode と同じ式（sRGB 原色のリニア → BT.2020 → Apple Log）を GPU で計算するカーネル。
    /// ビルド設定を増やさないよう実行時に Metal ソースからコンパイルする。失敗したら nil（CPU 版を使う）。
    /// 定数は CPU 版の Float 値をそのまま埋め込み、同じ値になるようにする。
    static let gpuKernel: CIColorKernel? = {
        func f(_ v: Float) -> String { "\(Double(v))f" }
        let source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        static float appleLogEncode1(float x) {
            if (x >= \(f(Rt))) { return min(\(f(gamma)) * precise::log2(x + \(f(beta))) + \(f(delta)), 1.0f); }
            if (x >= \(f(R0))) { float d = x - (\(f(R0))); return \(f(c)) * d * d; }
            return 0.0f;
        }

        [[stitchable]] float4 appleLogEncode(coreimage::sample_t s) {
            float3 rgb = s.rgb;
            float3 bt2020 = float3(dot(float3(0.6274f, 0.3293f, 0.0433f), rgb),
                                   dot(float3(0.0691f, 0.9195f, 0.0114f), rgb),
                                   dot(float3(0.0164f, 0.0880f, 0.8956f), rgb));
            return float4(appleLogEncode1(bt2020.r), appleLogEncode1(bt2020.g),
                          appleLogEncode1(bt2020.b), 1.0f);
        }
        """
        do {
            let kernels = try CIKernel.kernels(withMetalString: source)
            guard let kernel = kernels.first(where: { $0.name == "appleLogEncode" }) as? CIColorKernel else {
                dlog("raw", "GPU カーネルが見つからない（CPU で変換） kernels=\(kernels.map { $0.name })")
                return nil
            }
            dlog("raw", "GPU カーネル準備OK")
            return kernel
        } catch {
            dlog("raw", "GPU カーネルのコンパイル失敗（CPU で変換） \(error.localizedDescription)")
            return nil
        }
    }()

    /// encodeOnCPU と同じ結果（BT.2020 原色の Apple Log、8bit / 16bit RGB の CGImage）を GPU で作る。
    /// 帯ごとに RGBA で描いて RGB に詰める（出力の形式・大きさは CPU 版と同じ）。
    /// 描けなかった帯（途中でバックグラウンドに入り GPU が止められた等）を見つけたら nil を返す。
    static func encodeOnGPU(linearSRGB image: CIImage, context: CIContext,
                            sixteenBit: Bool) -> Encoded? {
        guard let kernel = gpuKernel else { return nil }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let encodedImage = kernel.apply(extent: extent, arguments: [image]) else { return nil }
        let bytesPerChannel = sixteenBit ? 2 : 1
        let outRowBytes = width * 3 * bytesPerChannel
        let stripRowBytes = width * 4 * bytesPerChannel
        let stripRows = max(1, min(height, (64 * 1024 * 1024) / stripRowBytes)) // 1 帯 ≈ 64MB
        // 出力は malloc で確保して Data へコピーせず渡す（48MP の 16bit で 290MB のコピーを省く）
        guard let out = malloc(outRowBytes * height) else { return nil }
        var handedOff = false
        defer { if !handedOff { free(out) } }
        var strip = [UInt8](repeating: 0, count: stripRowBytes * stripRows)
        var samples: [Float] = []
        samples.reserveCapacity(width * height / 256 + 1)
        let scale: Float = sixteenBit ? 1.0 / 65535 : 1.0 / 255
        var y0 = 0
        while y0 < height {
            let rows = min(stripRows, height - y0)
            // CIImage の座標は下が原点。出力は上から詰めるので帯の位置を反転して取り出す。
            let bounds = CGRect(x: extent.minX,
                                y: extent.maxY - CGFloat(y0 + rows),
                                width: CGFloat(width), height: CGFloat(rows))
            var zeroSamples = 0, takenSamples = 0
            strip.withUnsafeMutableBytes { raw in
                let base = raw.baseAddress!
                // 描かれなかった部分を見分けるため 0 で埋めてから描く。カーネルはアルファを常に 1 で
                // 返すので、描けた画素のアルファは最大値、描けなかった画素は 0 のまま残る。
                memset(base, 0, stripRowBytes * rows)
                // colorSpace: nil = 色変換なし（カーネルの出力＝ Log 符号値をそのまま書く）
                context.render(encodedImage, toBitmap: base, rowBytes: stripRowBytes, bounds: bounds,
                               format: sixteenBit ? .RGBA16 : .RGBA8, colorSpace: nil)
                let count = width * rows
                var i = 0
                while i < count {
                    let r, g, b, a: Float
                    if sixteenBit {
                        let p = base.assumingMemoryBound(to: UInt16.self)
                        r = Float(p[i * 4]) * scale; g = Float(p[i * 4 + 1]) * scale
                        b = Float(p[i * 4 + 2]) * scale; a = Float(p[i * 4 + 3])
                    } else {
                        let p = base.assumingMemoryBound(to: UInt8.self)
                        r = Float(p[i * 4]) * scale; g = Float(p[i * 4 + 1]) * scale
                        b = Float(p[i * 4 + 2]) * scale; a = Float(p[i * 4 + 3])
                    }
                    if a == 0 { zeroSamples += 1 }
                    samples.append(0.2627 * r + 0.6780 * g + 0.0593 * b)
                    takenSamples += 1
                    i += 256
                }
                // RGBA → RGB に詰めて出力へ置く
                var src = vImage_Buffer(data: base, height: vImagePixelCount(rows),
                                        width: vImagePixelCount(width), rowBytes: stripRowBytes)
                var dst = vImage_Buffer(data: out + y0 * outRowBytes, height: vImagePixelCount(rows),
                                        width: vImagePixelCount(width), rowBytes: outRowBytes)
                if sixteenBit {
                    vImageConvert_RGBA16UtoRGB16U(&src, &dst, vImage_Flags(kvImageNoFlags))
                } else {
                    vImageConvert_RGBA8888toRGB888(&src, &dst, vImage_Flags(kvImageNoFlags))
                }
            }
            if zeroSamples * 100 > takenSamples {
                dlog("raw", "GPU で描けなかった帯あり（\(y0)行目〜 未描画の画素 \(zeroSamples)/\(takenSamples)）")
                return nil
            }
            y0 += rows
        }
        strip = []
        samples.sort()
        let black = samples.isEmpty ? 0 : samples[samples.count / 100]
        let median = samples.isEmpty ? 0 : samples[samples.count / 2]
        let white = samples.isEmpty ? 0 : samples[samples.count * 99 / 100]
        let data = Data(bytesNoCopy: out, count: outRowBytes * height, deallocator: .free)
        handedOff = true
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height,
                               bitsPerComponent: sixteenBit ? 16 : 8,
                               bitsPerPixel: sixteenBit ? 48 : 24,
                               bytesPerRow: outRowBytes,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: sixteenBit
                                   ? (CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
                                   : CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return Encoded(image: cg, black: black, median: median, white: white)
    }

    /// CGImage をそのまま JPEG / TIFF にする（CIImage を経由せず、余計なコピーを作らない）。
    static func fileData(from image: CGImage, tiff: Bool) -> Data? {
        let out = NSMutableData()
        let type = (tiff ? "public.tiff" : "public.jpeg") as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        if tiff {
            CGImageDestinationAddImage(dest, image, nil)
        } else {
            CGImageDestinationAddImage(dest, image,
                [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
