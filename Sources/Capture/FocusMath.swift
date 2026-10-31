import Foundation

/// AF-S / AF-C / MF (Slice 2 §8).
enum FocusMode: String, Codable, CaseIterable, Sendable {
    case single = "AF-S"
    case continuous = "AF-C"
    case manual = "MF"
}

/// The MF wheel's velocity-dependent gain (§8).
enum FocusMath {
    /// Lens-position change per point of travel when moving slowly (fine).
    static let fineGain: Double = 0.0005
    /// … and when flicking fast (coarse).
    static let coarseGain: Double = 0.01
    /// Finger speeds (points per second) where the curve starts and saturates.
    static let slowSpeed: Double = 40
    static let fastSpeed: Double = 1600
    /// Detents per full lens travel.
    static let detentCount = 50

    /// Gain for a finger speed: a smooth log curve from `fineGain` to `coarseGain`.
    static func gain(forSpeed speed: Double) -> Double {
        let s = abs(speed)
        guard s > slowSpeed else { return fineGain }
        let t = min(1, log(s / slowSpeed) / log(fastSpeed / slowSpeed))
        // Smoothstep so the transition has no kink at either end.
        let eased = t * t * (3 - 2 * t)
        return fineGain * pow(coarseGain / fineGain, eased)
    }

    /// Extra resolution near infinity, where a small `lensPosition` change is visually large.
    static func infinityScale(atPosition position: Float) -> Double {
        let p = Double(ExposureMath.clamp(position, 0, 1))
        return 1 - 0.5 * p * p
    }

    /// New lens position after dragging `translation` points at `speed` points/second.
    /// Dragging right moves focus towards infinity.
    static func position(after translation: Double, speed: Double, from position: Float) -> Float {
        let delta = translation * gain(forSpeed: speed) * infinityScale(atPosition: position)
        return ExposureMath.clamp(position + Float(delta), 0, 1)
    }

    static func detentIndex(for position: Float) -> Int {
        Int((Double(ExposureMath.clamp(position, 0, 1)) * Double(detentCount)).rounded(.down))
    }
}

/// Finds the moment a focus pull passes the sharpest point (§8 "focus snap"). Feed it the
/// pipeline's edge-energy metric; it returns true once when the metric has risen clearly and then
/// dropped from its peak.
struct SharpnessPeakDetector: Sendable {
    /// The metric must rise this fraction above its running minimum before a peak can count.
    var riseFraction: Double = 0.15
    /// … and then fall this fraction below the peak.
    var dropFraction: Double = 0.06

    private var minimum: Double = .infinity
    private var maximum: Double = 0
    private var armed = false

    init(riseFraction: Double = 0.15, dropFraction: Double = 0.06) {
        self.riseFraction = riseFraction
        self.dropFraction = dropFraction
    }

    mutating func reset() {
        minimum = .infinity
        maximum = 0
        armed = false
    }

    /// - Returns: true exactly when a peak has just been passed.
    mutating func add(_ value: Double) -> Bool {
        guard value.isFinite, value >= 0 else { return false }
        if !armed {
            minimum = min(minimum, value)
            if value > minimum * (1 + riseFraction), value > 0 {
                armed = true
                maximum = value
            }
            return false
        }
        if value > maximum {
            maximum = value
            return false
        }
        if value < maximum * (1 - dropFraction) {
            // Peak passed: start looking for the next one from here.
            armed = false
            minimum = value
            maximum = 0
            return true
        }
        return false
    }
}

/// Level indicator with hysteresis (§9): level within ±0.5°, un-level beyond ±0.8°.
struct LevelIndicator: Sendable {
    static let enterThreshold: Double = 0.5
    static let exitThreshold: Double = 0.8

    private(set) var rollIsLevel = false
    private(set) var pitchIsLevel = false

    /// - Returns: true when the roll has just become level (fire the `level` haptic).
    mutating func update(rollDegrees: Double, pitchDegrees: Double) -> Bool {
        let rollDeviation = abs(RotationMath.deviationFromNearestRightAngle(rollDegrees))
        let wasLevel = rollIsLevel
        rollIsLevel = Self.next(rollIsLevel, deviation: rollDeviation)
        pitchIsLevel = Self.next(pitchIsLevel, deviation: abs(pitchDegrees))
        return rollIsLevel && !wasLevel
    }

    private static func next(_ current: Bool, deviation: Double) -> Bool {
        current ? deviation <= exitThreshold : deviation <= enterThreshold
    }
}
