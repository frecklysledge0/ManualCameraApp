import Foundation
import Observation

/// The control panel shown under the viewfinder (Slice 1 layout).
enum ControlPanel: String, CaseIterable, Sendable {
    case auto
    case manual
    case ev
    case whiteBalance
    case focus
}

enum ExposureMode: String, Codable, Sendable {
    case auto
    case manual
}

/// What the user has chosen. Views read and write this optimistically on the main thread; the
/// engine writes back the values it actually applied (clamped to the device). It is the single
/// source of truth for the lens and the camera position (F15).
@Observable
@MainActor
final class CameraSettings {

    var panel: ControlPanel = .auto

    // Exposure
    var exposureMode: ExposureMode = .auto
    var iso: Float = 100
    var shutter: Double = 1.0 / 60.0
    var bias: Float = 0

    // White balance
    var whiteBalanceAuto = true
    var temperature: Float = 5500
    var tint: Float = 0

    // Focus
    var focusManual = false
    var lensPosition: Float = 0.5

    // Lens
    var lens: LensOption?
    var lenses: [LensOption] = []
    var lastBackLens: LensOption?
    var limits: DeviceLimits = .default

    // Capture format
    var rawSupported = false
    var rawEnabled: Bool
    var rawSuppressedForStorage = false

    // Overlays
    var peakingEnabled = false
    var showGrid = false
    var showHistogram = true

    static let rawEnabledKey = "rawEnabled"

    init(defaults: UserDefaults = .standard) {
        rawEnabled = defaults.object(forKey: Self.rawEnabledKey) as? Bool ?? true
    }

    var isFrontCamera: Bool { lens?.isFront ?? false }

    /// RAW+HEIF only when the user wants it, the hardware supports it and storage allows it.
    var effectiveRaw: Bool { rawEnabled && rawSupported && !rawSuppressedForStorage }

    var backLenses: [LensOption] { lenses.filter { !$0.isFront } }

    var shutterStops: [Double] {
        ExposureMath.shutterStops(minDuration: limits.minDuration, maxDuration: limits.maxDuration)
    }

    var isoStops: [Float] {
        ExposureMath.isoStops(minISO: limits.minISO, maxISO: limits.maxISO)
    }

    var evStops: [Float] {
        ExposureMath.evStops(minBias: limits.minBias, maxBias: limits.maxBias, limit: 3)
    }
}
