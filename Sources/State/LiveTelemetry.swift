import Foundation
import Observation

/// Values that change many times a second. Only small leaf views read these, so a histogram
/// update never re-renders `CameraView` (F1).
@Observable
@MainActor
final class LiveTelemetry {
    var histogram = HistogramSample.empty

    /// Horizon roll in degrees (positive = phone turned clockwise) and forward tilt.
    var rollDegrees: Double = 0
    var pitchDegrees: Double = 0

    /// `exposureTargetOffset`: how far the current exposure is from the meter's target, in EV.
    var meterOffset: Float = 0

    /// What the camera is doing right now (auto values in AUTO).
    var liveISO: Float = 0
    var liveShutter: Double = 0
    var liveLensPosition: Float = 0
    var liveTemperature: Float = 0
    var liveAperture: Float = 0
    var isAdjustingFocus = false

    /// Level state with hysteresis (Slice 2 §9).
    var rollIsLevel = false
    var pitchIsLevel = false

    /// Free space ÷ average shot size for the current format.
    var shotsLeft: Int?

    /// Physical orientation and the matching glyph rotation (degrees, continuous).
    var orientation: PhysicalOrientation = .portrait
    var glyphAngle: Double = 0

    // Debug HUD
    var feedFPS: Double = 0
    var uiFPS: Double = 0
    var lastLatencyMS: Double = 0
}

/// Live values sampled from the device on the session queue.
struct LiveDeviceValues: Equatable, Sendable {
    var iso: Float
    var shutter: Double
    var lensPosition: Float
    var temperature: Float
    var aperture: Float
    var meterOffset: Float
    var isAdjustingFocus: Bool

    /// True when the change is big enough to be worth a UI update.
    func differsNoticeably(from other: LiveDeviceValues?) -> Bool {
        guard let other else { return true }
        if abs(iso - other.iso) >= 1 { return true }
        if other.shutter > 0, abs(log2(max(shutter, 1e-9) / other.shutter)) >= 0.02 { return true }
        if abs(lensPosition - other.lensPosition) >= 0.002 { return true }
        if abs(temperature - other.temperature) >= 25 { return true }
        if abs(aperture - other.aperture) >= 0.01 { return true }
        if abs(meterOffset - other.meterOffset) >= 0.03 { return true }
        return isAdjustingFocus != other.isAdjustingFocus
    }
}
