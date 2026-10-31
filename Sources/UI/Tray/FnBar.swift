import SwiftUI

/// The Quick Fn bar (Slice 2 §4): one tile per parameter plus `Fn`. Tap opens the dial tray,
/// long-press returns the parameter to AUTO.
struct FnBar: View {
    let controller: CameraController
    @Environment(\.cameraTheme) var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(theme.tiles, id: \.self) { tile in
                FnTileView(controller: controller, tile: tile)
            }
            FnSheetTile(controller: controller)
        }
        .padding(.horizontal, 6)
    }
}

/// One tile. Reads live values, so it re-renders on its own when the camera adjusts.
struct FnTileView: View {
    let controller: CameraController
    let tile: FnTile
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let settings = controller.settings
        let readout = Self.readout(for: tile, controller: controller)
        let isActive = settings.activeTile == tile
        let isDisabled = tile == .aperture && !settings.capability.hasVariableAperture
        VStack(spacing: 2) {
            Text(tile == .ev ? Readouts.evLabel(settings) : tile.label)
                .font(theme.tilesShowValues ? theme.labelFont : theme.labelFont.weight(.medium))
                .tracking(theme.labelTracking)
                .foregroundColor(labelColor(isActive: isActive))
            if theme.tilesShowValues || tile == .mode {
                // The Edition shows exposure values large in the strip, so its tiles carry only
                // their names (each value appears once on screen). The mode letter stays.
                Text(readout.text)
                    .font(theme.telemetryFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(valueColor(readout: readout, isActive: isActive))
            }
            if theme.tilesShowValues && readout.isAuto && tile != .mode {
                Text("AUTO")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isActive && theme.emphasisByInversion ? theme.background : theme.selection)
            }
        }
        .frame(maxWidth: .infinity, minHeight: theme.tileHeight)
        .background(tileBackground(isActive: isActive), in: RoundedRectangle(cornerRadius: theme.tileCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: theme.tileCornerRadius)
                .stroke(isActive && !theme.emphasisByInversion ? theme.selection : theme.hairline, lineWidth: 1)
        )
        .opacity(isDisabled ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(theme.trayAnimation) {
                controller.tapTile(tile)
            }
            controller.haptics.play(.detent)
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            controller.resetTileToAuto(tile)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityName(for: tile))
        .accessibilityValue(readout.isAuto ? "\(readout.text), auto" : readout.text)
        .accessibilityHint("Double-tap to open the dial. Long-press for auto.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            TileStepper.step(tile, controller: controller, by: direction == .increment ? 1 : -1)
        }
    }

    private func labelColor(isActive: Bool) -> Color {
        if isActive && theme.emphasisByInversion { return theme.background }
        if !theme.tilesShowValues { return isActive ? theme.text : theme.text.opacity(0.8) }
        return isActive ? theme.selection : theme.secondaryText
    }

    private func valueColor(readout: Readout, isActive: Bool) -> Color {
        if isActive && theme.emphasisByInversion { return theme.background }
        if tile == .ev && controller.settings.evIsMeteredManual && abs(controller.telemetry.meterOffset) > 3 {
            return theme.warning
        }
        return readout.isAuto ? theme.secondaryText : theme.text
    }

    private func tileBackground(isActive: Bool) -> Color {
        switch theme.tile {
        case .filled: return isActive ? theme.surfaceRaised : theme.surface
        case .minimal: return isActive ? theme.text : Color.clear
        }
    }

    static func readout(for tile: FnTile, controller: CameraController) -> Readout {
        let settings = controller.settings
        let telemetry = controller.telemetry
        switch tile {
        case .mode: return Readouts.mode(settings)
        case .aperture: return Readouts.aperture(settings, telemetry)
        case .shutter: return Readouts.shutter(settings, telemetry)
        case .iso: return Readouts.iso(settings, telemetry)
        case .ev: return Readouts.ev(settings, telemetry)
        case .whiteBalance: return Readouts.whiteBalance(settings, telemetry)
        case .focus: return Readouts.focus(settings)
        }
    }

    static func accessibilityName(for tile: FnTile) -> String {
        switch tile {
        case .mode: return "Exposure mode"
        case .aperture: return "Aperture"
        case .shutter: return "Shutter speed"
        case .iso: return "ISO"
        case .ev: return "Exposure compensation"
        case .whiteBalance: return "White balance"
        case .focus: return "Focus"
        }
    }
}

private struct FnSheetTile: View {
    let controller: CameraController
    @Environment(\.cameraTheme) var theme

    var body: some View {
        Button {
            controller.toggleFnSheet()
            controller.haptics.play(.detent)
        } label: {
            Text("Fn")
                .font(theme.telemetryFont.weight(.bold))
                .foregroundColor(theme.text)
                .frame(width: 40, height: theme.tileHeight)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.tileCornerRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.tileCornerRadius).stroke(theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Function menu")
    }
}

/// One-detent steps for VoiceOver's adjustable action (swipe up / down).
@MainActor
enum TileStepper {
    static func step(_ tile: FnTile, controller: CameraController, by delta: Int) {
        let settings = controller.settings
        switch tile {
        case .mode:
            let programs = settings.availablePrograms
            guard let index = programs.firstIndex(of: settings.program) else { return }
            let next = index + delta
            if programs.indices.contains(next) { controller.setProgram(programs[next]) }
        case .aperture:
            let stops = settings.apertureStops
            guard !stops.isEmpty else { return }
            let index = ExposureMath.nearestIndex(of: settings.exposure.aperture, in: stops) + delta
            if stops.indices.contains(index) { controller.setAperture(stops[index]) }
        case .shutter:
            let stops = settings.shutterStops
            let current = settings.program == .shutterPriority || settings.program == .manual ? settings.exposure.shutter : controller.telemetry.liveShutter
            // Larger value = longer exposure; "increment" means brighter (slower shutter).
            let index = ExposureMath.nearestIndex(of: current, in: stops) + delta
            if stops.indices.contains(index) { controller.setShutter(stops[index]) }
        case .iso:
            let stops = settings.isoStops
            let current = settings.program == .manual && !settings.exposure.isoAuto ? settings.exposure.iso : controller.telemetry.liveISO
            let index = ExposureMath.nearestIndex(of: current, in: stops) + delta
            if stops.indices.contains(index) { controller.setISO(stops[index]) }
        case .ev:
            let stops = settings.evStops
            let index = ExposureMath.nearestLinearIndex(of: settings.exposure.bias, in: stops) + delta
            if stops.indices.contains(index) { controller.setBias(stops[index]) }
        case .whiteBalance:
            let stops = WhiteBalanceTables.stops
            let index = WhiteBalanceTables.index(of: settings.whiteBalance) + delta
            if stops.indices.contains(index) { controller.setWhiteBalance(stops[index]) }
        case .focus:
            let modes = FocusMode.allCases
            guard let index = modes.firstIndex(of: settings.focusMode) else { return }
            let next = index + delta
            if modes.indices.contains(next) { controller.setFocusMode(modes[next]) }
        }
    }
}
