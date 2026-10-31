import SwiftUI

/// Keeps a glyph upright while the interface stays in portrait (Slice 1 §9). Reads only the glyph
/// angle, so rotating the phone re-renders just the rotated glyphs.
struct GlyphRotation: ViewModifier {
    let telemetry: LiveTelemetry
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(telemetry.glyphAngle))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.25), value: telemetry.glyphAngle)
    }
}

extension View {
    func rotatesWithDevice(_ telemetry: LiveTelemetry) -> some View {
        modifier(GlyphRotation(telemetry: telemetry))
    }
}

/// A readout value and whether it is currently chosen by the camera.
struct Readout: Equatable {
    var text: String
    var isAuto: Bool
}

/// Formats the current value of every parameter for tiles and the telemetry strip. Live values
/// come from `LiveTelemetry`, so only the views that call these re-render when the camera adjusts.
@MainActor
enum Readouts {

    static func mode(_ settings: CameraSettings) -> Readout {
        Readout(text: settings.program.badge, isAuto: settings.program == .program)
    }

    static func shutter(_ settings: CameraSettings, _ telemetry: LiveTelemetry) -> Readout {
        switch settings.program {
        case .shutterPriority, .manual:
            return Readout(text: ExposureMath.formatShutter(settings.exposure.shutter), isAuto: false)
        case .program, .aperturePriority:
            return Readout(text: ExposureMath.formatShutter(telemetry.liveShutter), isAuto: true)
        }
    }

    static func aperture(_ settings: CameraSettings, _ telemetry: LiveTelemetry) -> Readout {
        let live = telemetry.liveAperture > 0 ? telemetry.liveAperture : settings.limits.aperture
        guard settings.capability.hasVariableAperture else {
            return Readout(text: ExposureMath.formatAperture(live), isAuto: false)
        }
        switch settings.program {
        case .aperturePriority, .manual:
            return Readout(text: ExposureMath.formatAperture(settings.exposure.aperture), isAuto: false)
        case .program, .shutterPriority:
            return Readout(text: ExposureMath.formatAperture(live), isAuto: true)
        }
    }

    static func iso(_ settings: CameraSettings, _ telemetry: LiveTelemetry) -> Readout {
        if settings.program == .manual && !settings.exposure.isoAuto {
            return Readout(text: ExposureMath.formatISO(settings.exposure.iso), isAuto: false)
        }
        return Readout(text: ExposureMath.formatISO(telemetry.liveISO), isAuto: true)
    }

    /// EV, or the metered-manual offset in M with a fixed ISO (Slice 2 §6).
    static func ev(_ settings: CameraSettings, _ telemetry: LiveTelemetry) -> Readout {
        if settings.evIsMeteredManual {
            return Readout(text: ExposureMath.formatEV(telemetry.meterOffset), isAuto: false)
        }
        return Readout(text: ExposureMath.formatEV(settings.exposure.bias), isAuto: false)
    }

    static func evLabel(_ settings: CameraSettings) -> String {
        settings.evIsMeteredManual ? "M.M." : "EV"
    }

    static func whiteBalance(_ settings: CameraSettings, _ telemetry: LiveTelemetry) -> Readout {
        switch settings.whiteBalance {
        case .auto:
            let live = telemetry.liveTemperature
            return Readout(text: live > 0 ? ExposureMath.formatKelvin(live) : "AWB", isAuto: true)
        case .preset(let preset):
            return Readout(text: preset.label, isAuto: false)
        case .kelvin(let kelvin):
            return Readout(text: "\(kelvin)K", isAuto: false)
        }
    }

    static func focus(_ settings: CameraSettings) -> Readout {
        Readout(text: settings.focusMode.rawValue, isAuto: settings.focusMode != .manual)
    }

    static func shotsLeft(_ telemetry: LiveTelemetry) -> String {
        guard let shots = telemetry.shotsLeft else { return "—" }
        if shots >= 10000 { return "9999+" }
        return "\(shots)"
    }
}
