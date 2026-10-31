import Foundation

enum WhiteBalancePreset: String, Codable, CaseIterable, Sendable {
    case daylight
    case shade
    case cloudy
    case tungsten
    case fluorescent

    var kelvin: Float {
        switch self {
        case .daylight: return 5500
        case .shade: return 7500
        case .cloudy: return 6500
        case .tungsten: return 3200
        case .fluorescent: return 4000
        }
    }

    var label: String {
        switch self {
        case .daylight: return "DAY"
        case .shade: return "SHADE"
        case .cloudy: return "CLOUD"
        case .tungsten: return "TUNG"
        case .fluorescent: return "FLUOR"
        }
    }
}

/// One position on the WB dial (Slice 2 §5).
enum WhiteBalanceStop: Equatable, Hashable, Codable, Sendable {
    case auto
    case preset(WhiteBalancePreset)
    case kelvin(Int)

    /// Temperature to lock, or nil for AWB.
    var kelvinValue: Float? {
        switch self {
        case .auto: return nil
        case .preset(let preset): return preset.kelvin
        case .kelvin(let value): return Float(value)
        }
    }

    var label: String {
        switch self {
        case .auto: return "AWB"
        case .preset(let preset): return preset.label
        case .kelvin(let value): return "\(value)K"
        }
    }
}

enum WhiteBalanceTables {
    static let kelvinRange = 2500...10000
    static let kelvinStep = 100
    static let tintRange = -150...150
    static let tintStep = 10

    /// AWB, the presets in the spec's order, then 2500–10000 K in 100 K steps.
    static let stops: [WhiteBalanceStop] = {
        var stops: [WhiteBalanceStop] = [.auto]
        // `allCases` is declared in the spec's order: Daylight, Shade, Cloudy, Tungsten, Fluorescent.
        stops += WhiteBalancePreset.allCases.map { WhiteBalanceStop.preset($0) }
        stops += stride(from: kelvinRange.lowerBound, through: kelvinRange.upperBound, by: kelvinStep).map { WhiteBalanceStop.kelvin($0) }
        return stops
    }()

    /// −150…+150 in steps of 10.
    static let tintStops: [Float] = stride(from: tintRange.lowerBound, through: tintRange.upperBound, by: tintStep).map { Float($0) }

    /// Index of `stop` in `stops`, snapping an arbitrary Kelvin value to the nearest 100 K.
    static func index(of stop: WhiteBalanceStop) -> Int {
        if let exact = stops.firstIndex(of: stop) { return exact }
        if case .kelvin(let value) = stop {
            let snapped = ExposureMath.clamp((value + kelvinStep / 2) / kelvinStep * kelvinStep, kelvinRange.lowerBound, kelvinRange.upperBound)
            return stops.firstIndex(of: .kelvin(snapped)) ?? 0
        }
        return 0
    }

    static func tintIndex(of tint: Float) -> Int {
        ExposureMath.nearestLinearIndex(of: tint, in: tintStops)
    }
}
