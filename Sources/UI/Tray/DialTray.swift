import SwiftUI

/// The dial tray that slides up above the Fn bar for the active tile (Slice 2 §4–5).
struct DialTray: View {
    let controller: CameraController
    let tile: FnTile
    @Environment(\.cameraTheme) var theme

    var body: some View {
        VStack(spacing: 4) {
            switch tile {
            case .mode: ModeTray(controller: controller)
            case .aperture: ApertureTray(controller: controller)
            case .shutter: ShutterTray(controller: controller)
            case .iso: ISOTray(controller: controller)
            case .ev: EVTray(controller: controller)
            case .whiteBalance: WhiteBalanceTray(controller: controller)
            case .focus: FocusTray(controller: controller)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: theme.trayHeight)
        .frame(maxWidth: .infinity)
        .background(theme.surface.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.hairline).frame(height: 1)
        }
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height > 30, abs(value.translation.width) < value.translation.height {
                    withAnimation(theme.trayAnimation) { controller.dismissTray() }
                }
            }
        )
    }
}

/// A row of options (mode, focus mode, …).
struct SegmentedChoice<Option: Hashable>: View {
    let options: [Option]
    let selected: Option
    let label: (Option) -> String
    let onSelect: (Option) -> Void
    @Environment(\.cameraTheme) var theme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selected
                Button {
                    onSelect(option)
                } label: {
                    Text(label(option))
                        .font(theme.telemetryLargeFont.weight(.semibold))
                        .foregroundColor(isSelected ? (theme.emphasisByInversion ? theme.background : theme.selection) : theme.text)
                        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 40)
                        .background(
                            isSelected ? (theme.emphasisByInversion ? theme.text : theme.surfaceRaised) : Color.clear,
                            in: RoundedRectangle(cornerRadius: theme.tileCornerRadius)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.tileCornerRadius)
                                .stroke(isSelected && !theme.emphasisByInversion ? theme.selection : theme.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

private struct ModeTray: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        VStack(spacing: 6) {
            SegmentedChoice(options: settings.availablePrograms, selected: settings.program, label: { $0.badge }) { program in
                controller.setProgram(program)
            }
            if settings.program == .manual {
                Button {
                    controller.toggleAutoISO()
                } label: {
                    BadgeView(settings.exposure.isoAuto ? "AUTO ISO ON" : "AUTO ISO OFF", isActive: settings.exposure.isoAuto)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ApertureTray: View {
    let controller: CameraController
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let settings = controller.settings
        let stops = settings.apertureStops
        if settings.capability.hasVariableAperture, !stops.isEmpty {
            let isAuto = settings.isAutomatic(.aperture)
            let current = isAuto ? controller.telemetry.liveAperture : settings.exposure.aperture
            HStack(spacing: 8) {
                DialView(
                    stops: stops.map { DialStop(label: ExposureMath.formatAperture($0), isMajor: true) },
                    selectedIndex: ExposureMath.nearestIndex(of: current, in: stops),
                    isAuto: isAuto,
                    accessibilityName: "Aperture",
                    haptics: controller.haptics,
                    onSelect: { controller.setAperture(stops[$0]) },
                    onAuto: { controller.resetTileToAuto(.aperture) }
                )
                if current >= 3.95 {
                    // Diffraction hint at ƒ/4 (informational only).
                    BadgeView("DIFF", isActive: false)
                }
            }
        } else {
            VStack(spacing: 4) {
                Text(ExposureMath.formatAperture(settings.limits.aperture))
                    .font(theme.telemetryLargeFont)
                    .foregroundColor(theme.text)
                ThemeLabel("Fixed aperture on this lens")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ShutterTray: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        let stops = settings.shutterStops
        let isAuto = settings.isAutomatic(.shutter)
        let current = isAuto ? controller.telemetry.liveShutter : settings.exposure.shutter
        DialView(
            stops: stops.map { seconds in
                let major = ExposureMath.isFullStop(shutter: seconds)
                return DialStop(label: major ? ExposureMath.formatShutter(seconds) : nil, isMajor: major, spokenValue: ExposureMath.formatShutter(seconds))
            },
            selectedIndex: ExposureMath.nearestIndex(of: current, in: stops),
            isEnabled: stops.count > 1,
            isAuto: isAuto,
            accessibilityName: "Shutter speed",
            haptics: controller.haptics,
            onSelect: { controller.setShutter(stops[$0]) },
            onAuto: { controller.resetTileToAuto(.shutter) }
        )
    }
}

private struct ISOTray: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        let stops = settings.isoStops
        let isAuto = settings.isAutomatic(.iso)
        let current = isAuto ? controller.telemetry.liveISO : settings.exposure.iso
        DialView(
            stops: stops.map { iso in
                let major = ExposureMath.isFullStop(iso: iso)
                return DialStop(label: major ? ExposureMath.formatISO(iso) : nil, isMajor: major, spokenValue: ExposureMath.formatISO(iso))
            },
            selectedIndex: ExposureMath.nearestIndex(of: current, in: stops),
            isEnabled: stops.count > 1,
            isAuto: isAuto,
            accessibilityName: "ISO",
            haptics: controller.haptics,
            onSelect: { controller.setISO(stops[$0]) },
            onAuto: {
                if controller.settings.program == .manual { controller.resetTileToAuto(.iso) }
            }
        )
    }
}

private struct EVTray: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        if settings.evIsMeteredManual {
            MeteredManualScale(telemetry: controller.telemetry)
        } else {
            let stops = settings.evStops
            DialView(
                stops: stops.map { bias in
                    let major = abs(bias - bias.rounded()) < 0.01
                    return DialStop(label: major ? ExposureMath.formatEV(bias) : nil, isMajor: major, spokenValue: ExposureMath.formatEV(bias))
                },
                selectedIndex: ExposureMath.nearestLinearIndex(of: settings.exposure.bias, in: stops),
                isEnabled: stops.count > 1,
                accessibilityName: "Exposure compensation",
                haptics: controller.haptics,
                onSelect: { controller.setBias(stops[$0]) },
                onAuto: { controller.setBias(0) }
            )
        }
    }
}

/// M.M. (metered manual): the live meter offset on a ±3 EV scale (Slice 2 §6).
private struct MeteredManualScale: View {
    let telemetry: LiveTelemetry
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let offset = telemetry.meterOffset
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = geometry.size.width
                Canvas { context, size in
                    for step in -9...9 {
                        let x = width / 2 + CGFloat(step) / 9 * (width / 2 - 8)
                        let major = step % 3 == 0
                        let rect = CGRect(x: x - 0.5, y: major ? 4 : 8, width: 1, height: major ? 14 : 8)
                        context.fill(Path(rect), with: .color(major ? theme.text : theme.secondaryText))
                    }
                    let clamped = CGFloat(ExposureMath.clamp(offset, -3, 3))
                    let markerX = width / 2 + clamped / 3 * (width / 2 - 8)
                    let marker = Path(CGRect(x: markerX - 2, y: 0, width: 4, height: 22))
                    context.fill(marker, with: .color(abs(offset) > 3 ? theme.warning : theme.selection))
                }
            }
            .frame(height: 24)
            HStack {
                ThemeLabel("−3")
                Spacer()
                Text("M.M. \(ExposureMath.formatEV(offset))")
                    .font(theme.telemetryFont)
                    .monospacedDigit()
                    .foregroundColor(theme.text)
                Spacer()
                ThemeLabel("+3")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Metered manual")
        .accessibilityValue("\(ExposureMath.formatEV(offset)) EV")
    }
}

private struct WhiteBalanceTray: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        let stops = WhiteBalanceTables.stops
        let tints = WhiteBalanceTables.tintStops
        VStack(spacing: 2) {
            DialView(
                stops: stops.map { stop in
                    switch stop {
                    case .auto, .preset:
                        return DialStop(label: stop.label, isMajor: true)
                    case .kelvin(let kelvin):
                        let major = kelvin % 1000 == 0
                        return DialStop(label: major ? "\(kelvin / 100 * 100)K" : nil, isMajor: major)
                    }
                },
                selectedIndex: WhiteBalanceTables.index(of: settings.whiteBalance),
                isAuto: settings.whiteBalance == .auto,
                accessibilityName: "White balance",
                haptics: controller.haptics,
                onSelect: { controller.setWhiteBalance(stops[$0]) },
                onAuto: { controller.setWhiteBalance(.auto) }
            )
            .frame(height: 42)
            HStack(spacing: 6) {
                ThemeLabel("Tint")
                DialView(
                    stops: tints.map { DialStop(label: nil, isMajor: Int($0) % 50 == 0) },
                    selectedIndex: WhiteBalanceTables.tintIndex(of: settings.tint),
                    accessibilityName: "Tint",
                    haptics: controller.haptics,
                    onSelect: { controller.setTint(tints[$0]) },
                    onAuto: { controller.setTint(0) }
                )
                TintReadout(tint: settings.tint)
            }
            .frame(height: 24)
        }
    }
}

private struct TintReadout: View {
    let tint: Float
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let value = Int(tint.rounded())
        Text(value == 0 ? "±0" : (value > 0 ? "G\(value)" : "M\(-value)"))
            .font(theme.telemetryFont)
            .monospacedDigit()
            .foregroundColor(theme.text)
            .frame(width: 44, alignment: .trailing)
    }
}

private struct FocusTray: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        // Tray content is 80 pt tall: 30 (mode) + 4 + 44 (wheel 28 + 4 + bar 12).
        VStack(spacing: 4) {
            SegmentedChoice(options: FocusMode.allCases, selected: settings.focusMode, label: { $0.rawValue }) { mode in
                controller.setFocusMode(mode)
            }
            .frame(height: 30)
            MFWheel(
                position: settings.focusMode == .manual ? settings.lensPosition : controller.telemetry.liveLensPosition,
                onBegan: { controller.mfWheelBegan() },
                onMoved: { delta, speed in controller.mfWheelMoved(by: delta, speed: speed) },
                onEnded: { controller.mfWheelEnded() }
            )
        }
    }
}
