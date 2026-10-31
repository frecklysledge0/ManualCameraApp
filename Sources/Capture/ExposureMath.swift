import Foundation

/// Pure exposure arithmetic: 1/3-stop tables, log mapping, clamping and readout formatting.
///
/// Nothing in here touches AVFoundation, so every function is covered by `ExposureMathTests`.
enum ExposureMath {

    // MARK: - Stop tables

    /// Nominal 1/3-stop shutter speeds in seconds, fastest first (1/40000 s … 30 s).
    static let nominalShutterSpeeds: [Double] = {
        let fastDenominators: [Double] = [
            40000, 32000, 25000, 20000, 16000, 12800, 10000,
            8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000,
            800, 640, 500, 400, 320, 250, 200, 160, 125, 100,
            80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4
        ]
        let slowSeconds: [Double] = [
            0.3, 0.4, 0.5, 0.6, 0.8, 1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30
        ]
        return fastDenominators.map { 1.0 / $0 } + slowSeconds
    }()

    /// Nominal 1/3-stop ISO values, lowest first.
    static let nominalISOs: [Float] = [
        25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
        1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600
    ]

    /// A device endpoint is appended to a table when it lies more than this many stops beyond the
    /// nearest nominal value, so the full hardware range stays reachable.
    static let endpointToleranceStops: Double = 1.0 / 6.0

    /// 1/3-stop shutter table clamped to the device range (seconds, fastest first).
    static func shutterStops(minDuration: Double, maxDuration: Double) -> [Double] {
        stops(from: nominalShutterSpeeds, min: minDuration, max: maxDuration)
    }

    /// 1/3-stop ISO table clamped to the device range (lowest first).
    static func isoStops(minISO: Float, maxISO: Float) -> [Float] {
        stops(from: nominalISOs.map { Double($0) }, min: Double(minISO), max: Double(maxISO)).map { Float($0) }
    }

    /// EV bias values in 1/3 steps within ±`limit`, clamped to the device bias range.
    static func evStops(minBias: Float, maxBias: Float, limit: Float = 3) -> [Float] {
        let lower = max(minBias, -limit)
        let upper = min(maxBias, limit)
        guard lower <= upper else { return [0] }
        let first = Int((lower * 3).rounded(.up))
        let last = Int((upper * 3).rounded(.down))
        guard first <= last else { return [clamp(0, lower, upper)] }
        return (first...last).map { Float($0) / 3 }
    }

    /// Filters a positive, ascending nominal table to `[min, max]` and adds the device endpoints
    /// when they would otherwise be unreachable.
    static func stops(from nominal: [Double], min lower: Double, max upper: Double) -> [Double] {
        guard lower > 0, upper > 0 else { return [] }
        let lo = Swift.min(lower, upper)
        let hi = Swift.max(lower, upper)
        let slack = 1e-6
        var result = nominal.filter { $0 >= lo * (1 - slack) && $0 <= hi * (1 + slack) }
        guard let first = result.first, let last = result.last else {
            return lo == hi ? [lo] : [lo, hi]
        }
        if stopsBetween(lo, first) > endpointToleranceStops { result.insert(lo, at: 0) }
        if stopsBetween(last, hi) > endpointToleranceStops { result.append(hi) }
        return result
    }

    // MARK: - Log mapping

    /// Number of stops from `a` to `b` (positive when `b` is larger).
    static func stopsBetween(_ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0 else { return 0 }
        return log2(b / a)
    }

    /// Index of the table entry closest to `value` in log space. Returns 0 for an empty table.
    static func nearestIndex(of value: Double, in table: [Double]) -> Int {
        guard !table.isEmpty else { return 0 }
        guard value > 0 else { return 0 }
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, entry) in table.enumerated() where entry > 0 {
            let distance = abs(log2(value / entry))
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    static func nearestIndex(of value: Float, in table: [Float]) -> Int {
        nearestIndex(of: Double(value), in: table.map { Double($0) })
    }

    /// Index of the linear-closest entry (used for EV, which is already logarithmic).
    static func nearestLinearIndex(of value: Float, in table: [Float]) -> Int {
        guard !table.isEmpty else { return 0 }
        var best = 0
        for index in table.indices where abs(table[index] - value) < abs(table[best] - value) {
            best = index
        }
        return best
    }

    /// Position of `value` between `lower` and `upper` on a log scale, in `0...1`.
    static func logFraction(of value: Double, lower: Double, upper: Double) -> Double {
        guard lower > 0, upper > lower, value > 0 else { return 0 }
        return clamp(log(value / lower) / log(upper / lower), 0, 1)
    }

    /// Inverse of `logFraction`.
    static func value(atLogFraction fraction: Double, lower: Double, upper: Double) -> Double {
        guard lower > 0, upper > lower else { return lower }
        let f = clamp(fraction, 0, 1)
        return lower * pow(upper / lower, f)
    }

    // MARK: - Clamping

    static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }

    // MARK: - Formatting

    /// Shutter readout: `1/125`, `1/4`, `0.5s`, `1s`, `2.5s`.
    static func formatShutter(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 0.29 {
            let denominator = Int((1.0 / seconds).rounded())
            return "1/\(max(denominator, 1))"
        }
        if seconds < 1 {
            return String(format: "%.1fs", seconds)
        }
        let rounded = seconds.rounded()
        if abs(seconds - rounded) < 0.05 {
            return "\(Int(rounded))s"
        }
        return String(format: "%.1fs", seconds)
    }

    static func formatISO(_ iso: Float) -> String {
        guard iso.isFinite, iso > 0 else { return "—" }
        return "\(Int(iso.rounded()))"
    }

    /// EV readout with one decimal, `±0.0` at zero.
    static func formatEV(_ bias: Float) -> String {
        guard bias.isFinite else { return "—" }
        if abs(bias) < 0.05 { return "±0.0" }
        return String(format: "%+.1f", bias)
    }

    /// Aperture readout: `ƒ/1.48`, `ƒ/1.8`, `ƒ/4`.
    static func formatAperture(_ fNumber: Float) -> String {
        guard fNumber.isFinite, fNumber > 0 else { return "ƒ/—" }
        let tenths = (fNumber * 10).rounded()
        if abs(fNumber * 10 - tenths) < 0.05 {
            if abs(fNumber - fNumber.rounded()) < 0.05 {
                return "ƒ/\(Int(fNumber.rounded()))"
            }
            return String(format: "ƒ/%.1f", fNumber)
        }
        return String(format: "ƒ/%.2f", fNumber)
    }

    /// Full stops get labelled major ticks on the dials (Slice 2 §5).
    static let fullStopShutterSpeeds: [Double] = [
        1.0 / 32000, 1.0 / 16000, 1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250,
        1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 0.5, 1, 2, 4, 8, 15, 30
    ]
    static let fullStopISOs: [Float] = [25, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600]

    static func isFullStop(shutter seconds: Double) -> Bool {
        fullStopShutterSpeeds.contains { abs($0 - seconds) / $0 < 0.01 }
    }

    /// The 1/3-stop ƒ-numbers engraved on lens barrels.
    static let thirdStopApertures: [Float] = [
        1.0, 1.1, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5, 2.8, 3.2, 3.5, 4.0, 4.5, 5.0, 5.6,
        6.3, 7.1, 8.0, 9.0, 10, 11, 13, 14, 16, 18, 20, 22
    ]
    static let fullStopApertures: [Float] = [1.0, 1.4, 2.0, 2.8, 4.0, 5.6, 8.0, 11, 16, 22]

    /// Every 1/3 stop from the lens's widest to its smallest aperture: the exact ends, Apple's
    /// recommended stops and the standard third stops between them (Slice 3 follow-up: full
    /// aperture control instead of only the recommended stops). Values closer than ~1/12 stop
    /// collapse into one, preferring the exact end or a recommended stop.
    static func apertureTable(min minimum: Float, max maximum: Float, recommended: [Float]) -> [Float] {
        guard minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return [] }
        guard maximum / minimum > 1.01 else { return [minimum] }
        let preferred = ([minimum, maximum] + recommended.filter { $0 >= minimum * 0.999 && $0 <= maximum * 1.001 })
        let standard = thirdStopApertures.filter { $0 > minimum && $0 < maximum }
        var table: [Float] = []
        for value in (preferred + standard).sorted() {
            if let last = table.last, value / last < 1.03 {
                // Keep the preferred one of two near-duplicates.
                if preferred.contains(value) && !preferred.contains(last) { table[table.count - 1] = value }
                continue
            }
            table.append(value)
        }
        return table
    }

    static func isFullStop(aperture: Float) -> Bool {
        fullStopApertures.contains { abs($0 - aperture) / $0 < 0.02 }
    }

    static func isFullStop(iso: Float) -> Bool {
        fullStopISOs.contains { abs($0 - iso) / $0 < 0.01 }
    }

    static func formatKelvin(_ kelvin: Float) -> String {
        guard kelvin.isFinite, kelvin > 0 else { return "—" }
        return "\(Int((kelvin / 100).rounded()) * 100)K"
    }
}

/// Pure white-balance gain handling. AVFoundation throws an exception when locked gains fall
/// outside `[1, maxWhiteBalanceGain]`, so every gain triple goes through `clampGains` first.
enum WhiteBalanceMath {
    struct Gains: Equatable, Sendable {
        var red: Float
        var green: Float
        var blue: Float
    }

    static func clampGains(_ gains: Gains, maxGain: Float) -> Gains {
        let upper = max(1, maxGain)
        func safe(_ value: Float) -> Float {
            guard value.isFinite else { return 1 }
            return ExposureMath.clamp(value, 1, upper)
        }
        return Gains(red: safe(gains.red), green: safe(gains.green), blue: safe(gains.blue))
    }
}
