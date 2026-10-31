import SwiftUI

/// The telemetry strip above the 4:3 image (Slice 2 §4, §9):
/// mode badge · SS · F · ISO · EV/M.M. · WB · RAW · shots left, then the mini histogram and the
/// two-axis level. Every value is its own leaf view, so a live ISO change re-renders one `Text`.
struct TelemetryStrip: View {
    let controller: CameraController
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let settings = controller.settings
        if settings.histogramExpanded {
            HistogramView(telemetry: controller.telemetry, mode: settings.overlays.histogramMode)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { controller.toggleHistogramExpanded() }
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    BadgeView(settings.program.badge)
                    StripValue(controller: controller, tile: .shutter)
                    StripValue(controller: controller, tile: .aperture)
                    StripValue(controller: controller, tile: .iso)
                    StripValue(controller: controller, tile: .ev)
                    if theme.telemetry == .dense {
                        StripValue(controller: controller, tile: .whiteBalance)
                    }
                    Spacer(minLength: 0)
                    if settings.effectiveRaw {
                        BadgeView("RAW")
                    }
                    if theme.telemetry == .dense {
                        ShotsLeftView(telemetry: controller.telemetry)
                    }
                }
                HStack(spacing: 10) {
                    HistogramView(telemetry: controller.telemetry, mode: theme.telemetry == .minimal ? .luma : settings.overlays.histogramMode)
                        .frame(width: 84, height: 22)
                        .contentShape(Rectangle())
                        .onTapGesture { controller.toggleHistogramExpanded() }
                    Spacer(minLength: 0)
                    if settings.overlays.levelEnabled {
                        LevelView(telemetry: controller.telemetry)
                            .frame(width: 120, height: 22)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}

/// One live value in the strip.
private struct StripValue: View {
    let controller: CameraController
    let tile: FnTile
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let readout = FnTileView.readout(for: tile, controller: controller)
        HStack(spacing: 2) {
            if tile == .iso {
                Text("ISO").font(theme.labelFont).foregroundColor(theme.secondaryText)
            } else if tile == .ev {
                Text(Readouts.evLabel(controller.settings)).font(theme.labelFont).foregroundColor(theme.secondaryText)
            }
            Text(readout.text)
                .font(theme.telemetryFont)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundColor(readout.isAuto ? theme.secondaryText : theme.text)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FnTileView.accessibilityName(for: tile))
        .accessibilityValue(readout.text)
    }
}

private struct ShotsLeftView: View {
    let telemetry: LiveTelemetry
    @Environment(\.cameraTheme) var theme

    var body: some View {
        Text("[\(Readouts.shotsLeft(telemetry))]")
            .font(theme.telemetryFont)
            .monospacedDigit()
            .foregroundColor(theme.secondaryText)
            .accessibilityLabel("Shots left \(Readouts.shotsLeft(telemetry))")
    }
}

/// Sony-style horizon bar (roll) with a pitch bubble. Both turn to the emphasis colour within
/// ±0.5° (with hysteresis, see `LevelIndicator`).
struct LevelView: View {
    let telemetry: LiveTelemetry
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let roll = RotationMath.deviationFromNearestRightAngle(telemetry.rollDegrees)
        let pitch = telemetry.pitchDegrees
        let rollColor = telemetry.rollIsLevel ? theme.emphasis : theme.text
        let pitchColor = telemetry.pitchIsLevel ? theme.emphasis : theme.secondaryText
        Canvas { context, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            // Fixed reference ticks.
            for x in [mid.x - 40, mid.x + 40] {
                context.fill(Path(CGRect(x: x - 6, y: mid.y - 0.5, width: 12, height: 1)), with: .color(theme.secondaryText))
            }
            // Horizon bar, rotated by the roll deviation (clamped to ±20° for display).
            let angle = -ExposureMath.clamp(roll, -20, 20) * .pi / 180
            var bar = Path()
            bar.move(to: CGPoint(x: -32, y: 0))
            bar.addLine(to: CGPoint(x: 32, y: 0))
            let transform = CGAffineTransform(translationX: mid.x, y: mid.y).rotated(by: angle)
            context.stroke(bar.applying(transform), with: .color(rollColor), lineWidth: 2)
            // Pitch bubble moves vertically (±10° full scale).
            let offset = CGFloat(ExposureMath.clamp(pitch, -10, 10) / 10) * (size.height / 2 - 3)
            let bubble = CGRect(x: mid.x - 3, y: mid.y - 3 - offset, width: 6, height: 6)
            context.stroke(Path(ellipseIn: bubble), with: .color(pitchColor), lineWidth: 1.5)
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(String(format: "Roll %.1f degrees, pitch %.1f degrees", roll, pitch))
    }
}
