import Foundation

/// P / A / S / M (Slice 2 §6).
enum ExposureProgram: String, Codable, CaseIterable, Sendable {
    case program = "P"
    case aperturePriority = "A"
    case shutterPriority = "S"
    case manual = "M"

    var badge: String { rawValue }

    var isAutomatic: Bool { self == .program }

    /// A/S/M use `.speed` so locked values are honoured; P uses `.balanced` (F6).
    var usesSpeedPrioritization: Bool { self != .program }
}

/// What the hardware can do with exposure and aperture.
struct ExposureCapability: Equatable, Sendable {
    /// True on lenses with a moving iris (iPhone 18 Pro main camera) when the iOS 27 API is present.
    var hasVariableAperture = false
    /// `recommendedLensApertureStops`, ascending ƒ-numbers.
    var apertureStops: [Float] = []
    var minAperture: Float = 1.8
    var maxAperture: Float = 1.8
    /// `setExposureModeCustom(lensAperture:duration:iso:)` accepts Auto duration / Auto ISO.
    var supportsAperturePriority = false
    var supportsShutterPriority = false
    var supportsManualAperture = false

    static let fixed = ExposureCapability()

    /// Modes the user can pick: A only with a moving iris (§6 "Hidden").
    var availablePrograms: [ExposureProgram] {
        supportsAperturePriority ? [.program, .aperturePriority, .shutterPriority, .manual] : [.program, .shutterPriority, .manual]
    }
}

/// The user's exposure values for the current mode.
struct ExposureValues: Equatable, Codable, Sendable {
    var iso: Float = 100
    var shutter: Double = 1.0 / 125.0
    var aperture: Float = 1.8
    var bias: Float = 0
    /// Auto ISO in M (Sony style).
    var isoAuto = false
}

/// What the camera is doing right now, used to lock values on a mode change.
struct LiveExposure: Equatable, Sendable {
    var iso: Float
    var shutter: Double
    var aperture: Float
}

/// Auto-ISO control loop target (emulated S, and M with Auto ISO, §6).
struct AutoISOLoop: Equatable, Sendable {
    var duration: Double
    var bias: Float
    /// Fixed aperture for the iOS 27 path, nil to leave the iris alone.
    var aperture: Float?
}

/// How a mode is realised on the device: one command, plus the auto-ISO loop when emulated.
struct ExposurePlan: Equatable, Sendable {
    var command: ExposureCommand
    var loop: AutoISOLoop?
}

enum ExposureRules {

    /// Locks the current auto values when switching modes so the image never jumps (§6).
    static func transition(from old: ExposureProgram, to new: ExposureProgram, values: ExposureValues, live: LiveExposure) -> ExposureValues {
        var result = values
        guard old != new else { return result }
        let liveISO = live.iso > 0 ? live.iso : values.iso
        let liveShutter = live.shutter > 0 ? live.shutter : values.shutter
        let liveAperture = live.aperture > 0 ? live.aperture : values.aperture

        switch new {
        case .program:
            break
        case .aperturePriority:
            // Keep a user-chosen aperture from M; otherwise freeze the current iris.
            result.aperture = old == .manual ? values.aperture : liveAperture
        case .shutterPriority:
            result.shutter = old == .manual ? values.shutter : liveShutter
        case .manual:
            switch old {
            case .shutterPriority:
                result.iso = liveISO
                result.aperture = liveAperture
            case .aperturePriority:
                result.iso = liveISO
                result.shutter = liveShutter
            case .program, .manual:
                result.iso = liveISO
                result.shutter = liveShutter
                result.aperture = liveAperture
            }
            result.isoAuto = false
        }
        return result
    }

    /// Turns a mode and its values into a device plan for the given capability.
    static func plan(for program: ExposureProgram, values: ExposureValues, live: LiveExposure, capability: ExposureCapability) -> ExposurePlan {
        let currentISO = live.iso > 0 ? live.iso : values.iso
        switch program {
        case .program:
            return ExposurePlan(command: .auto(bias: values.bias), loop: nil)

        case .aperturePriority:
            if capability.supportsAperturePriority {
                return ExposurePlan(command: .priority(aperture: values.aperture, duration: nil, iso: nil, bias: values.bias), loop: nil)
            }
            // A is hidden without a moving iris; fall back to P.
            return ExposurePlan(command: .auto(bias: values.bias), loop: nil)

        case .shutterPriority:
            if capability.supportsShutterPriority {
                return ExposurePlan(command: .priority(aperture: nil, duration: values.shutter, iso: nil, bias: values.bias), loop: nil)
            }
            return ExposurePlan(
                command: .custom(iso: currentISO, duration: values.shutter),
                loop: AutoISOLoop(duration: values.shutter, bias: values.bias, aperture: nil)
            )

        case .manual:
            let aperture: Float? = capability.supportsManualAperture ? values.aperture : nil
            if values.isoAuto {
                if capability.supportsShutterPriority {
                    return ExposurePlan(command: .priority(aperture: aperture, duration: values.shutter, iso: nil, bias: values.bias), loop: nil)
                }
                return ExposurePlan(
                    command: .custom(iso: currentISO, duration: values.shutter),
                    loop: AutoISOLoop(duration: values.shutter, bias: values.bias, aperture: aperture)
                )
            }
            if let aperture {
                return ExposurePlan(command: .priority(aperture: aperture, duration: values.shutter, iso: values.iso, bias: 0), loop: nil)
            }
            return ExposurePlan(command: .custom(iso: values.iso, duration: values.shutter), loop: nil)
        }
    }
}

/// The emulated auto-ISO loop (§6). Each tick estimates the ISO the meter wants from the ISO it
/// actually measured with, then moves part of the way there. Because the estimate uses the
/// observed ISO, a frame of meter latency causes no overshoot.
enum ExposureLoopMath {
    static let gain: Double = 0.6
    static let deadbandStops: Double = 1.0 / 12.0
    static let maxStepStops: Double = 2

    /// - Parameters:
    ///   - commanded: The ISO last sent to the device.
    ///   - observed: The ISO the device reports for the metered frame (`AVCaptureDevice.iso`).
    ///   - meterOffset: `exposureTargetOffset` in EV (positive = brighter than the target).
    ///   - bias: Desired offset in EV (exposure compensation).
    /// - Returns: The next ISO, or nil when already within the deadband.
    static func nextISO(commanded: Float, observed: Float, meterOffset: Float, bias: Float, minISO: Float, maxISO: Float) -> Float? {
        guard commanded > 0, observed > 0, meterOffset.isFinite else { return nil }
        let wanted = Double(observed) * pow(2, -Double(meterOffset - bias))
        let error = log2(Double(commanded) / wanted)
        guard abs(error) >= deadbandStops else { return nil }
        let step = ExposureMath.clamp(-gain * error, -maxStepStops, maxStepStops)
        let next = Float(Double(commanded) * pow(2, step))
        let clamped = ExposureMath.clamp(next, min(minISO, maxISO), max(minISO, maxISO))
        return abs(clamped - commanded) < 0.5 ? nil : clamped
    }
}
