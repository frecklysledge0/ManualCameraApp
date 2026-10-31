import SwiftUI
import UIKit

/// The Sony Alpha-style status header above the 4:3 viewfinder:
/// Mode badge · Focus mode · Format (RAW+HEIF / HEIF) · Aspect ratio · Shots left · Battery level,
/// with the live histogram and two-axis level horizon below it.
/// Note: Exposure parameters (SS, F, ISO, EV) belong exclusively in the interactive Fn bar at the bottom.
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
        // Top row: Sony Alpha status information (no duplicated exposure controls)
        HStack(spacing: 8) {
          BadgeView(settings.program.badge)
          SonyPillBadge(text: settings.focusMode.rawValue)
          if settings.isFrontCamera {
            SonyPillBadge(text: "FRONT")
          }

          Spacer(minLength: 4)

          BadgeView(settings.effectiveRaw ? "RAW+HEIF" : "HEIF", isActive: settings.effectiveRaw)
          Text("4:3")
            .font(theme.labelFont)
            .foregroundColor(theme.secondaryText)

          Spacer(minLength: 4)

          ShotsLeftView(telemetry: controller.telemetry)
          SonyBatteryView()
        }

        // Bottom row: Histogram & Horizon Level gauge
        HStack(spacing: 10) {
          HistogramView(
            telemetry: controller.telemetry,
            mode: theme.telemetry == .minimal ? .luma : settings.overlays.histogramMode
          )
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

private struct SonyPillBadge: View {
  let text: String
  @Environment(\.cameraTheme) var theme

  var body: some View {
    Text(text)
      .font(theme.labelFont.weight(.semibold))
      .tracking(theme.labelTracking)
      .foregroundColor(theme.secondaryText)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: theme.badgeCornerRadius))
  }
}

private struct SonyBatteryView: View {
  @Environment(\.cameraTheme) var theme
  @State private var batteryPercent: Int = 100

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: batteryIconName)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(batteryColor)
      Text("\(batteryPercent)%")
        .font(theme.telemetryFont)
        .monospacedDigit()
        .foregroundColor(theme.secondaryText)
    }
    .onAppear {
      UIDevice.current.isBatteryMonitoringEnabled = true
      let level = UIDevice.current.batteryLevel
      batteryPercent = level < 0 ? 100 : max(1, Int(level * 100))
    }
  }

  private var batteryIconName: String {
    if batteryPercent > 75 { return "battery.100" }
    if batteryPercent > 50 { return "battery.75" }
    if batteryPercent > 25 { return "battery.50" }
    return "battery.25"
  }

  private var batteryColor: Color {
    batteryPercent <= 20 ? theme.warning : theme.secondaryText
  }
}

private struct ShotsLeftView: View {
  let telemetry: LiveTelemetry
  @Environment(\.cameraTheme) var theme

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: "sdcard.fill")
        .font(.system(size: 9))
        .foregroundColor(theme.secondaryText)
      Text("[\(Readouts.shotsLeft(telemetry))]")
        .font(theme.telemetryFont)
        .monospacedDigit()
        .foregroundColor(theme.secondaryText)
    }
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
        context.fill(
          Path(CGRect(x: x - 6, y: mid.y - 0.5, width: 12, height: 1)),
          with: .color(theme.secondaryText))
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
