import Foundation

enum GridMode: String, Codable, CaseIterable, Sendable {
    case off
    case thirds
    case square

    var label: String {
        switch self {
        case .off: return "OFF"
        case .thirds: return "3×3"
        case .square: return "SQUARE"
        }
    }
}

enum HistogramMode: String, Codable, CaseIterable, Sendable {
    case rgb
    case luma

    var label: String { self == .rgb ? "RGB" : "LUMA" }
}

enum PeakingColor: String, Codable, CaseIterable, Sendable {
    case cinnabar
    case red
    case yellow
    case white
    case blue

    var label: String { rawValue.uppercased() }

    /// Linear RGBA used by the Metal overlay.
    var rgba: SIMD4<Float> {
        switch self {
        case .cinnabar: return SIMD4(1.0, 0.333, 0.0, 0.95)
        case .red: return SIMD4(1.0, 0.1, 0.1, 0.95)
        case .yellow: return SIMD4(1.0, 0.9, 0.0, 0.95)
        case .white: return SIMD4(1.0, 1.0, 1.0, 0.9)
        case .blue: return SIMD4(0.2, 0.55, 1.0, 0.95)
        }
    }
}

enum PeakingLevel: String, Codable, CaseIterable, Sendable {
    case low
    case mid
    case high

    var label: String { rawValue.uppercased() }

    /// Sobel threshold: a lower threshold marks more edges.
    var threshold: Float {
        switch self {
        case .low: return 0.32
        case .mid: return 0.22
        case .high: return 0.14
        }
    }
}

/// Zebra thresholds (§9) as luma fractions; 100+ marks only clipped pixels.
enum ZebraThreshold: Int, Codable, CaseIterable, Sendable {
    case p70 = 70
    case p80 = 80
    case p90 = 90
    case p95 = 95
    case p100 = 100

    var label: String { self == .p100 ? "100+" : "\(rawValue)" }
    var luma: Float { self == .p100 ? 0.99 : Float(rawValue) / 100 }
}

enum ThemeID: String, Codable, CaseIterable, Sendable {
    case alpha
    case edition
}

struct OverlaySettings: Equatable, Codable, Sendable {
    var peakingInAF = false
    var peakingColor: PeakingColor = .cinnabar
    var peakingLevel: PeakingLevel = .mid
    var zebrasEnabled = false
    var zebraThreshold: ZebraThreshold = .p95
    var grid: GridMode = .off
    var levelEnabled = true
    var levelLine = false
    var histogramMode: HistogramMode = .rgb
}

struct HapticSettings: Equatable, Codable, Sendable {
    var enabled = true
    /// 0.5…1.0
    var intensity: Float = 1.0
}

/// Everything restored on launch (Slice 2 §11), stored as JSON in `UserDefaults`.
/// Decoding tolerates missing keys so later slices can add fields without losing settings.
struct ShootingProfile: Equatable, Codable, Sendable {
    var program: ExposureProgram = .program
    /// Per-mode values: each mode remembers its own shutter/ISO/aperture/bias.
    var modeValues: [String: ExposureValues] = [:]
    var lensKind: LensKind = .wide
    var focusMode: FocusMode = .continuous
    var whiteBalance: WhiteBalanceStop = .auto
    var tint: Float = 0
    var overlays = OverlaySettings()
    var rawEnabled = true
    var haptics = HapticSettings()
    var theme: ThemeID = .alpha

    static let storageKey = "shootingProfile.v1"

    init() {}

    func values(for program: ExposureProgram) -> ExposureValues {
        modeValues[program.rawValue] ?? ExposureValues()
    }

    mutating func setValues(_ values: ExposureValues, for program: ExposureProgram) {
        modeValues[program.rawValue] = values
    }

    // MARK: Persistence

    static func load(from defaults: UserDefaults) -> ShootingProfile {
        guard let data = defaults.data(forKey: storageKey),
              let profile = try? JSONDecoder().decode(ShootingProfile.self, from: data) else {
            var fresh = ShootingProfile()
            // Carry over the Slice 1 RAW toggle.
            if let raw = defaults.object(forKey: "rawEnabled") as? Bool { fresh.rawEnabled = raw }
            return fresh
        }
        return profile
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: Codable (lenient)

    private enum CodingKeys: String, CodingKey {
        case program, modeValues, lensKind, focusMode, whiteBalance, tint, overlays, rawEnabled, haptics, theme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ShootingProfile()
        program = (try? container.decodeIfPresent(ExposureProgram.self, forKey: .program)) ?? defaults.program
        modeValues = (try? container.decodeIfPresent([String: ExposureValues].self, forKey: .modeValues)) ?? defaults.modeValues
        lensKind = (try? container.decodeIfPresent(LensKind.self, forKey: .lensKind)) ?? defaults.lensKind
        focusMode = (try? container.decodeIfPresent(FocusMode.self, forKey: .focusMode)) ?? defaults.focusMode
        whiteBalance = (try? container.decodeIfPresent(WhiteBalanceStop.self, forKey: .whiteBalance)) ?? defaults.whiteBalance
        tint = (try? container.decodeIfPresent(Float.self, forKey: .tint)) ?? defaults.tint
        overlays = (try? container.decodeIfPresent(OverlaySettings.self, forKey: .overlays)) ?? defaults.overlays
        rawEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .rawEnabled)) ?? defaults.rawEnabled
        haptics = (try? container.decodeIfPresent(HapticSettings.self, forKey: .haptics)) ?? defaults.haptics
        theme = (try? container.decodeIfPresent(ThemeID.self, forKey: .theme)) ?? defaults.theme
    }
}
