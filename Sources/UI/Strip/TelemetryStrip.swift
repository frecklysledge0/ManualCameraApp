import SwiftUI
import UIKit

/// The status area above the viewfinder. Every value appears in exactly one place on screen:
/// - Pro theme (`.dense`): an Alpha-style status header (mode · AF · format · aspect · shots left ·
///   battery) over the histogram and level. Exposure values live on the Fn bar below.
/// - Edition (`.minimal`): the exposure values themselves, large and light, with a luma outline
///   histogram and a hairline level. The Fn tiles below show only their names.
struct TelemetryStrip: View {
  let controller: CameraController
  @Environment(\.cameraTheme) var theme

  var body: some View {
    let settings = controller.settings
    if settings.histogramExpanded {
      HistogramView(telemetry: controller.telemetry, mode: theme.telemetry == .minimal ? .luma : settings.overlays.histogramMode)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { controller.toggleHistogramExpanded() }
        .accessibilityHint("Double-tap to collapse the histogram.")
    } else {
      switch theme.telemetry {
      case .dense: ProStatusHeader(controller: controller)
      case .minimal: EditionReadoutStrip(controller: controller)
      }
    }
  }
}

// MARK: - Pro theme

private struct ProStatusHeader: View {
  let controller: CameraController
  @Environment(\.cameraTheme) var theme

  var body: some View {
    let settings = controller.settings
    VStack(spacing: 6) {
      HStack(spacing: 6) {
        BadgeView(settings.program.badge)
        StatusPill(text: settings.focusMode.rawValue)
        if settings.isFrontCamera {
          StatusPill(text: "FRONT")
        }
        Spacer(minLength: 6)
        FormatBadge(controller: controller)
        EditionSwitch(controller: controller)
        Spacer(minLength: 6)
        ShotsLeftView(telemetry: controller.telemetry)
        BatteryView()
      }
      .frame(height: 20)

      HStack(spacing: 10) {
        HistogramView(telemetry: controller.telemetry, mode: settings.overlays.histogramMode)
          .frame(width: 84, height: 22)
          .contentShape(Rectangle())
          .onTapGesture { controller.toggleHistogramExpanded() }
          .accessibilityHint("Double-tap to enlarge the histogram.")
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

/// The capture format; a tap cycles HEIF → RAW → RAW+HEIF.
private struct FormatBadge: View {
  let controller: CameraController

  var body: some View {
    let settings = controller.settings
    let format = settings.effectiveFormat
    Button {
      controller.cycleCaptureFormat()
    } label: {
      BadgeView(format.label, isActive: format.includesRaw)
    }
    .buttonStyle(.plain)
    .disabled(!settings.rawSupported)
    .accessibilityLabel("Format \(format.label)")
    .accessibilityHint(settings.rawSupported ? "Double-tap to change the format." : "")
  }
}

/// One tap in and out of the Medium Format Edition: an outlined "MF" in the Pro theme, inverted
/// (active) inside the Edition.
private struct EditionSwitch: View {
  let controller: CameraController

  var body: some View {
    let isEdition = controller.settings.isEdition
    Button {
      controller.setEdition(!isEdition)
    } label: {
      BadgeView("MF", isActive: isEdition)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Branding.editionName)
    .accessibilityValue(isEdition ? "On" : "Off")
    .accessibilityHint(isEdition ? "Double-tap to return to the Pro interface." : "Double-tap to switch on.")
  }
}

private struct StatusPill: View {
  let text: String
  @Environment(\.cameraTheme) var theme

  var body: some View {
    Text(text)
      .font(theme.labelFont.weight(.semibold))
      .tracking(theme.labelTracking)
      .foregroundColor(theme.text)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: theme.badgeCornerRadius))
  }
}

// MARK: - Edition

private struct EditionReadoutStrip: View {
  let controller: CameraController
  @Environment(\.cameraTheme) var theme

  var body: some View {
    let settings = controller.settings
    let telemetry = controller.telemetry
    VStack(spacing: 4) {
      HStack(spacing: 8) {
        EditionSwitch(controller: controller)
        Button {
          controller.cycleFraming()
        } label: {
          BadgeView(settings.framing.label)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Framing \(settings.framing.label)")
        .accessibilityHint("Double-tap to change the framing.")
        ThemeLabel(settings.effectiveFormat.label)
        Spacer(minLength: 6)
        HistogramView(telemetry: telemetry, mode: .luma, showsFrame: false)
          .frame(width: 64, height: 16)
          .contentShape(Rectangle())
          .onTapGesture { controller.toggleHistogramExpanded() }
        Spacer(minLength: 6)
        if settings.overlays.levelEnabled {
          HairlineLevel(telemetry: telemetry)
            .frame(width: 56, height: 16)
        }
        ThemeLabel(Readouts.shotsLeft(telemetry))
          .monospacedDigit()
          .accessibilityLabel("Shots left \(Readouts.shotsLeft(telemetry))")
      }
      .frame(height: 20)

      HStack(alignment: .lastTextBaseline, spacing: 0) {
        LargeReadout(label: "SS", readout: Readouts.shutter(settings, telemetry))
        LargeReadout(label: "F", readout: Readouts.aperture(settings, telemetry))
        LargeReadout(label: "ISO", readout: Readouts.iso(settings, telemetry))
        LargeReadout(
          label: Readouts.evLabel(settings),
          readout: Readouts.ev(settings, telemetry),
          warning: settings.evIsMeteredManual && abs(telemetry.meterOffset) > 3
        )
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 4)
  }
}

/// One large, light exposure value with its name above. Camera-chosen values are dimmed.
private struct LargeReadout: View {
  let label: String
  let readout: Readout
  var warning = false
  @Environment(\.cameraTheme) var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ThemeLabel(readout.isAuto ? "\(label) · auto" : label)
      Text(readout.text)
        .font(theme.readoutFont)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .foregroundColor(warning ? theme.warning : (readout.isAuto ? theme.secondaryText : theme.text))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label)
    .accessibilityValue(readout.isAuto ? "\(readout.text), auto" : readout.text)
  }
}

/// The Edition's level: one hairline that rotates with the roll and turns solid when level.
private struct HairlineLevel: View {
  let telemetry: LiveTelemetry
  @Environment(\.cameraTheme) var theme

  var body: some View {
    let roll = RotationMath.deviationFromNearestRightAngle(telemetry.rollDegrees)
    let level = telemetry.rollIsLevel
    Canvas { context, size in
      let mid = CGPoint(x: size.width / 2, y: size.height / 2)
      let angle = -ExposureMath.clamp(roll, -20, 20) * .pi / 180
      var line = Path()
      line.move(to: CGPoint(x: -size.width / 2, y: 0))
      line.addLine(to: CGPoint(x: size.width / 2, y: 0))
      let transform = CGAffineTransform(translationX: mid.x, y: mid.y).rotated(by: angle)
      context.stroke(line.applying(transform), with: .color(level ? theme.text : theme.secondaryText), lineWidth: level ? 1.5 : 0.75)
    }
    .accessibilityElement()
    .accessibilityLabel("Level")
    .accessibilityValue(level ? "Level" : String(format: "%.1f degrees", roll))
  }
}

// MARK: - Shared pieces

/// Battery level and charging state, updated from UIDevice notifications.
private struct BatteryView: View {
  @Environment(\.cameraTheme) var theme
  @State private var level: Float = -1
  @State private var charging = false

  var body: some View {
    let percent = level < 0 ? nil : max(1, Int((level * 100).rounded()))
    HStack(spacing: 3) {
      Image(systemName: iconName(percent))
        .font(.system(size: 12, weight: .regular))
        .foregroundColor(percent.map { $0 <= 20 && !charging } == true ? theme.warning : theme.secondaryText)
      Text(percent.map { "\($0)%" } ?? "—")
        .font(theme.telemetryFont)
        .monospacedDigit()
        .foregroundColor(theme.secondaryText)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Battery")
    .accessibilityValue(percent.map { "\($0) percent\(charging ? ", charging" : "")" } ?? "Unknown")
    .onAppear {
      UIDevice.current.isBatteryMonitoringEnabled = true
      refresh()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in refresh() }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in refresh() }
  }

  private func refresh() {
    level = UIDevice.current.batteryLevel
    let state = UIDevice.current.batteryState
    charging = state == .charging || state == .full
  }

  private func iconName(_ percent: Int?) -> String {
    if charging { return "battery.100.bolt" }
    guard let percent else { return "battery.100" }
    if percent > 85 { return "battery.100" }
    if percent > 60 { return "battery.75" }
    if percent > 35 { return "battery.50" }
    if percent > 10 { return "battery.25" }
    return "battery.0"
  }
}

private struct ShotsLeftView: View {
  let telemetry: LiveTelemetry
  @Environment(\.cameraTheme) var theme

  var body: some View {
    let shots = Readouts.shotsLeft(telemetry)
    HStack(spacing: 3) {
      Image(systemName: "sdcard")
        .font(.system(size: 10))
        .foregroundColor(theme.secondaryText)
      Text(shots)
        .font(theme.telemetryFont)
        .monospacedDigit()
        .foregroundColor(theme.text)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Shots left")
    .accessibilityValue(shots)
  }
}

/// Alpha-style horizon bar (roll) with a pitch bubble. Both turn to the confirmation colour within
/// ±0.5° (with hysteresis, see `LevelIndicator`).
struct LevelView: View {
  let telemetry: LiveTelemetry
  @Environment(\.cameraTheme) var theme

  var body: some View {
    let roll = RotationMath.deviationFromNearestRightAngle(telemetry.rollDegrees)
    let pitch = telemetry.pitchDegrees
    let rollColor = telemetry.rollIsLevel ? theme.confirmation : theme.text
    let pitchColor = telemetry.pitchIsLevel ? theme.confirmation : theme.secondaryText
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
