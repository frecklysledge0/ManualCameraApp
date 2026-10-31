import CoreGraphics
import Foundation

/// Framing in the Medium Format Edition (Slice 3 §5).
enum FramingMode: String, Codable, CaseIterable, Sendable {
    /// 4:3, the sensor's native frame.
    case native
    /// 1:1 (6×6).
    case square
    /// 65:24 panoramic (XPAN-style).
    case xpan

    var label: String {
        switch self {
        case .native: return "4:3"
        case .square: return "1:1"
        case .xpan: return "XPAN"
        }
    }

    /// Long side : short side of the output.
    var longToShort: CGFloat {
        switch self {
        case .native: return 4.0 / 3.0
        case .square: return 1
        case .xpan: return 65.0 / 24.0
        }
    }
}

enum GrainLevel: String, Codable, CaseIterable, Sendable {
    case off
    case fine
    case medium

    var label: String { rawValue.capitalized }
}

enum ShutterSoundVolume: String, Codable, CaseIterable, Sendable {
    case off
    case low
    case medium

    var label: String { rawValue.capitalized }

    var gain: Float {
        switch self {
        case .off: return 0
        case .low: return 0.35
        case .medium: return 0.7
        }
    }
}

/// One of the Edition's looks (generated into `LookConstants.looks` by tools/look/make_look.py).
struct LookDescriptor: Equatable, Sendable {
    var id: String
    var name: String
    /// `.cube` resource name in the bundle.
    var resource: String
    var lutSize: Int

    static let defaultID = "natural"

    /// The look with `id`, or the base look when it is unknown (for example, removed later).
    static func find(_ id: String) -> LookDescriptor {
        LookConstants.looks.first { $0.id == id } ?? LookConstants.looks[0]
    }
}

/// Pure framing maths, shared by the preview mattes and the developed output.
enum FramingMath {

    /// The centred crop for `mode` inside an image of `size`. The ratio applies along the image's
    /// own long side, so a landscape 8064×6048 frame gives 6048×6048 (1:1) or 8064×2977 (XPAN), and
    /// a portrait frame gives the same sizes turned on end. Results are whole pixels.
    static func cropRect(for mode: FramingMode, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, mode != .native else {
            return CGRect(origin: .zero, size: size)
        }
        let landscape = size.width >= size.height
        let long = landscape ? size.width : size.height
        let short = landscape ? size.height : size.width
        var cropLong = long
        var cropShort = max(1, (long / mode.longToShort).rounded(.down))
        if cropShort > short {
            cropShort = short
            cropLong = min(long, max(1, (short * mode.longToShort).rounded(.down)))
        }
        let width = landscape ? cropLong : cropShort
        let height = landscape ? cropShort : cropLong
        return CGRect(
            x: ((size.width - width) / 2).rounded(.down),
            y: ((size.height - height) / 2).rounded(.down),
            width: width,
            height: height
        )
    }
}

/// Pure grain maths (Slice 3 §6 step 4).
enum GrainMath {

    /// Noise texel size in output pixels: proportional to the output height, so a 6×6 crop has
    /// the same grain relative to the frame as a full 4:3 image.
    static func scale(forImageHeight height: CGFloat, level: GrainLevel) -> Float {
        let size: Float = level == .medium ? LookConstants.grainMediumSize : LookConstants.grainFineSize
        let relative = Float(max(height, 1)) / LookConstants.grainReferenceHeight
        return max(0.5, size * relative)
    }

    static func amplitude(for level: GrainLevel, iso: Float) -> Float {
        let base: Float
        switch level {
        case .off: return 0
        case .fine: base = LookConstants.grainFineAmplitude
        case .medium: base = LookConstants.grainMediumAmplitude
        }
        return base * isoBoost(iso: iso)
    }

    /// Grain rises slightly with ISO: +12% per stop above ISO 100, capped.
    static func isoBoost(iso: Float) -> Float {
        let stops = max(0, log2(max(iso, 1) / 100))
        return min(LookConstants.grainISOBoostMax, 1 + LookConstants.grainISOBoostPerStop * stops)
    }

    /// A deterministic per-photo seed from its capture ID.
    static func seed(for id: UUID) -> UInt32 {
        // FNV-1a over the UUID bytes.
        var hash: UInt32 = 2_166_136_261
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt32(byte)
                hash = hash &* 16_777_619
            }
        }
        return hash
    }

    /// Three octave offsets in [0, 1) derived from the seed (one per octave).
    static func octaveOffsets(seed: UInt32) -> [SIMD2<Float>] {
        var state = seed == 0 ? 0x9E37_79B9 : seed
        func next() -> Float {
            // xorshift32
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return Float(state % 1_000_003) / 1_000_003
        }
        return (0..<3).map { _ in SIMD2<Float>(next(), next()) }
    }
}

/// CIEDE2000 colour difference (Sharma, Wu & Dalal 2005), used by the golden-image tests and the
/// preview-vs-still check.
enum DeltaE {
    struct Lab: Equatable {
        var l: Double
        var a: Double
        var b: Double
    }

    static func ciede2000(_ lab1: Lab, _ lab2: Lab) -> Double {
        let c1 = (lab1.a * lab1.a + lab1.b * lab1.b).squareRoot()
        let c2 = (lab2.a * lab2.a + lab2.b * lab2.b).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * lab1.a
        let a2p = (1 + g) * lab2.a
        let c1p = (a1p * a1p + lab1.b * lab1.b).squareRoot()
        let c2p = (a2p * a2p + lab2.b * lab2.b).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            if b == 0 && a == 0 { return 0 }
            let h = atan2(b, a) * 180 / .pi
            return h >= 0 ? h : h + 360
        }
        let h1p = hue(lab1.b, a1p)
        let h2p = hue(lab2.b, a2p)
        let dLp = lab2.l - lab1.l
        let dCp = c2p - c1p
        var dhp: Double = 0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp * .pi / 360)
        let lBarp = (lab1.l + lab2.l) / 2
        let cBarp = (c1p + c2p) / 2
        var hBarp = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 {
                hBarp = (h1p + h2p) / 2
            } else if h1p + h2p < 360 {
                hBarp = (h1p + h2p + 360) / 2
            } else {
                hBarp = (h1p + h2p - 360) / 2
            }
        }
        let rad = Double.pi / 180
        let t = 1 - 0.17 * cos((hBarp - 30) * rad) + 0.24 * cos(2 * hBarp * rad)
            + 0.32 * cos((3 * hBarp + 6) * rad) - 0.20 * cos((4 * hBarp - 63) * rad)
        let dTheta = 30 * exp(-pow((hBarp - 275) / 25, 2))
        let cBarp7 = pow(cBarp, 7)
        let rc = 2 * (cBarp7 / (cBarp7 + pow(25, 7))).squareRoot()
        let lTerm = pow(lBarp - 50, 2)
        let sl = 1 + 0.015 * lTerm / (20 + lTerm).squareRoot()
        let sc = 1 + 0.045 * cBarp
        let sh = 1 + 0.015 * cBarp * t
        let rt = -sin(2 * dTheta * rad) * rc
        let lPart = dLp / sl
        let cPart = dCp / sc
        let hPart = dHp / sh
        return (lPart * lPart + cPart * cPart + hPart * hPart + rt * cPart * hPart).squareRoot()
    }

    /// sRGB-encoded (0…1) to CIE L*a*b* (D65).
    static func lab(fromSRGB r: Double, _ g: Double, _ b: Double) -> Lab {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        let x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16) / 116 }
        return Lab(l: 116 * f(y) - 16, a: 500 * (f(x) - f(y)), b: 200 * (f(y) - f(z)))
    }
}

/// Parses a `.cube` 3D LUT (red fastest) into RGBA floats.
enum CubeLUT {
    struct Table: Equatable {
        var size: Int
        /// size³ entries, RGBA (alpha 1), red fastest.
        var rgba: [Float]
        var sourceHash: String?
    }

    enum ParseError: Error, Equatable {
        case missingSize
        case wrongCount(expected: Int, found: Int)
    }

    static func parse(_ text: String) throws -> Table {
        var size = 0
        var hash: String?
        var values: [Float] = []
        values.reserveCapacity(65 * 65 * 65 * 4)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first else { continue }
            if first == "#" {
                if line.hasPrefix("# source-sha256:") {
                    hash = line.dropFirst("# source-sha256:".count).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if first.isLetter {
                if line.hasPrefix("LUT_3D_SIZE") {
                    size = Int(line.split(separator: " ").last ?? "") ?? 0
                    values.reserveCapacity(size * size * size * 4)
                }
                continue
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else { continue }
            values.append(r)
            values.append(g)
            values.append(b)
            values.append(1)
        }
        guard size > 1 else { throw ParseError.missingSize }
        let expected = size * size * size * 4
        guard values.count == expected else { throw ParseError.wrongCount(expected: expected / 4, found: values.count / 4) }
        return Table(size: size, rgba: values, sourceHash: hash)
    }
}
