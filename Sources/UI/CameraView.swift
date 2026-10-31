import SwiftUI

/// Root view. It reads only rarely-changing state (authorization, grid toggle); everything that
/// updates per frame lives in leaf views that read `LiveTelemetry` themselves (F1).
struct CameraView: View {
    let controller: CameraController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch controller.status.authorization {
            case .denied, .restricted:
                PermissionView(authorization: controller.status.authorization) {
                    controller.perform(.openSettings, for: .noCamera)
                }
            case .unknown, .authorized:
                ViewfinderLayer(controller: controller)
                HUDLayer(controller: controller)
                CaptureFlashView(status: controller.status)
                    .ignoresSafeArea()
            }
        }
        .onAppear {
            controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                controller.sceneBecameActive()
            case .background:
                controller.sceneEnteredBackground()
            default:
                break
            }
        }
    }
}

/// The camera image and everything drawn over it.
private struct ViewfinderLayer: View {
    let controller: CameraController

    var body: some View {
        ZStack {
            CameraPreviewView(controller: controller)
                .ignoresSafeArea()

            if controller.settings.showGrid {
                GridOverlayView(telemetry: controller.telemetry)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            FocusBoxView(status: controller.status)
                .ignoresSafeArea()

            Image(systemName: "plus.viewfinder")
                .font(.system(size: 60, weight: .ultraLight))
                .foregroundColor(.white.opacity(0.8))
                .opacity(0.5)
                .allowsHitTesting(false)

            InterruptionOverlay(status: controller.status)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

/// Controls over the viewfinder, in the original layout.
private struct HUDLayer: View {
    let controller: CameraController

    var body: some View {
        VStack(spacing: 0) {
            TopBar(controller: controller)
                .padding(.horizontal, 20)
                .padding(.top, 10)

            HistogramSlot(controller: controller)

            BannerStack(status: controller.status) { banner in
                controller.perform(banner.action, for: banner.kind)
            }
            .padding(.top, 8)

            #if DEBUG
            DebugHUD(telemetry: controller.telemetry)
                .padding(.top, 4)
            #endif

            Spacer(minLength: 0)

            BottomControls(controller: controller)
        }
    }
}

private struct HistogramSlot: View {
    let controller: CameraController

    var body: some View {
        if controller.settings.showHistogram {
            HistogramView(telemetry: controller.telemetry)
                .frame(width: 80, height: 40)
                .padding(.top, 8)
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    let controller: CameraController
    private let hudColor = Color.black.opacity(0.6)
    private let textGray = Color.white.opacity(0.8)

    var body: some View {
        HStack {
            ShutterReadout(controller: controller)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hudColor)
                .cornerRadius(6)

            Spacer()

            Button {
                controller.select(.ev)
            } label: {
                Image(systemName: "plusminus.circle")
                    .font(.system(size: 22))
                    .foregroundColor(textGray)
                    .rotatesWithDevice(controller.telemetry)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exposure compensation")

            Spacer()

            ISOReadout(controller: controller)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hudColor)
                .cornerRadius(6)

            Spacer()

            Button {
                controller.toggleFrontCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 20))
                    .foregroundColor(textGray)
                    .rotatesWithDevice(controller.telemetry)
            }
            .buttonStyle(.plain)
            .disabled(controller.settings.lenses.first(where: { $0.isFront }) == nil)
            .accessibilityLabel("Switch camera")
        }
    }
}

/// Shows the manual value in MANUAL and the live auto value otherwise.
private struct ShutterReadout: View {
    let controller: CameraController

    var body: some View {
        let manual = controller.settings.exposureMode == .manual
        let seconds = manual ? controller.settings.shutter : controller.telemetry.liveShutter
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.system(size: 12))
            Text(ExposureMath.formatShutter(seconds))
                .font(.system(.subheadline, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundColor(.white)
        .rotatesWithDevice(controller.telemetry)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shutter \(ExposureMath.formatShutter(seconds))")
    }
}

private struct ISOReadout: View {
    let controller: CameraController

    var body: some View {
        let manual = controller.settings.exposureMode == .manual
        let iso = manual ? controller.settings.iso : controller.telemetry.liveISO
        HStack(spacing: 4) {
            Text("ISO")
                .font(.system(size: 10, weight: .bold))
            Text(ExposureMath.formatISO(iso))
                .font(.system(.subheadline, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundColor(.white)
        .rotatesWithDevice(controller.telemetry)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ISO \(ExposureMath.formatISO(iso))")
    }
}

// MARK: - Bottom controls

private struct BottomControls: View {
    let controller: CameraController

    var body: some View {
        VStack(spacing: 15) {
            ModeRow(controller: controller)
                .padding(.bottom, 5)

            HStack(spacing: 20) {
                RawToggle(controller: controller)
                Spacer()
                LensSwitcher(controller: controller)
            }
            .padding(.horizontal, 25)

            PanelControls(controller: controller)
                .padding(.bottom, 10)

            ShutterBar(controller: controller)
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
        }
        .background(
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}

private struct ModeRow: View {
    let controller: CameraController

    var body: some View {
        let current = controller.settings.panel
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 30) {
                Spacer(minLength: 10)
                TextModeButton(title: "AUTO", panel: .auto, current: current, action: { controller.select($0) })
                TextModeButton(title: "MANUAL", panel: .manual, current: current, action: { controller.select($0) })
                TextModeButton(title: "EV", panel: .ev, current: current, action: { controller.select($0) })
                TextModeButton(title: "WB", panel: .whiteBalance, current: current, action: { controller.select($0) })
                TextModeButton(title: "FOCUS", panel: .focus, current: current, action: { controller.select($0) })
                Spacer(minLength: 10)
            }
        }
    }
}

/// RAW pill (F13). Hidden when the device has no RAW format; struck through while storage is low.
private struct RawToggle: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        if settings.rawSupported {
            CapsuleTextButton(
                title: "RAW",
                isSelected: settings.effectiveRaw,
                color: .white,
                isStruckThrough: settings.rawSuppressedForStorage,
                action: { controller.toggleRaw() }
            )
            .rotatesWithDevice(controller.telemetry)
            .accessibilityLabel(settings.effectiveRaw ? "RAW plus HEIF on" : "RAW off")
        }
    }
}

private struct LensSwitcher: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        let lenses = settings.backLenses
        if !lenses.isEmpty, !settings.isFrontCamera {
            HStack(spacing: 0) {
                ForEach(lenses) { lens in
                    LensButton(lens: lens, isSelected: lens == settings.lens) {
                        controller.switchLens(lens)
                    }
                    .rotatesWithDevice(controller.telemetry)
                }
            }
            .background(Color.black.opacity(0.6))
            .cornerRadius(15)
        }
    }
}

/// The slider(s) for the active panel.
private struct PanelControls: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        switch settings.panel {
        case .manual:
            VStack(spacing: 5) {
                ShutterSlider(controller: controller)
                ISOSlider(controller: controller)
            }
        case .auto, .ev:
            if settings.exposureMode == .auto {
                EVSlider(controller: controller)
            } else {
                MeterReadout(controller: controller)
            }
        case .whiteBalance:
            WhiteBalanceSlider(controller: controller)
        case .focus:
            FocusSlider(controller: controller)
        }
    }
}

private struct ShutterSlider: View {
    let controller: CameraController

    var body: some View {
        let stops = controller.settings.shutterStops
        let index = ExposureMath.nearestIndex(of: controller.settings.shutter, in: stops)
        RulerSlider(
            label: "SS",
            fraction: SliderMapping.fraction(index: index, count: stops.count),
            steps: stops.count,
            readout: ExposureMath.formatShutter(controller.settings.shutter),
            isEnabled: stops.count > 1,
            haptics: controller.haptics
        ) { fraction in
            let newIndex = SliderMapping.index(fraction: fraction, count: stops.count)
            guard stops.indices.contains(newIndex) else { return }
            controller.setShutter(stops[newIndex])
        }
    }
}

private struct ISOSlider: View {
    let controller: CameraController

    var body: some View {
        let stops = controller.settings.isoStops
        let index = ExposureMath.nearestIndex(of: controller.settings.iso, in: stops)
        RulerSlider(
            label: "ISO",
            fraction: SliderMapping.fraction(index: index, count: stops.count),
            steps: stops.count,
            readout: ExposureMath.formatISO(controller.settings.iso),
            isEnabled: stops.count > 1,
            haptics: controller.haptics
        ) { fraction in
            let newIndex = SliderMapping.index(fraction: fraction, count: stops.count)
            guard stops.indices.contains(newIndex) else { return }
            controller.setISO(stops[newIndex])
        }
    }
}

private struct EVSlider: View {
    let controller: CameraController

    var body: some View {
        let stops = controller.settings.evStops
        let index = ExposureMath.nearestLinearIndex(of: controller.settings.bias, in: stops)
        RulerSlider(
            label: "EV",
            fraction: SliderMapping.fraction(index: index, count: stops.count),
            steps: stops.count,
            readout: ExposureMath.formatEV(controller.settings.bias),
            isEnabled: stops.count > 1,
            haptics: controller.haptics
        ) { fraction in
            let newIndex = SliderMapping.index(fraction: fraction, count: stops.count)
            guard stops.indices.contains(newIndex) else { return }
            controller.setBias(stops[newIndex])
        }
    }
}

/// In MANUAL the EV row shows the meter offset read-only (F7).
private struct MeterReadout: View {
    let controller: CameraController

    var body: some View {
        let offset = controller.telemetry.meterOffset
        RulerSlider(
            label: "METER",
            fraction: Double((ExposureMath.clamp(offset, -3, 3) + 3) / 6),
            steps: nil,
            readout: ExposureMath.formatEV(offset),
            isEnabled: false,
            haptics: controller.haptics
        ) { _ in }
    }
}

private struct WhiteBalanceSlider: View {
    let controller: CameraController
    private let lower: Float = 3000
    private let upper: Float = 8000
    private let step: Float = 100

    var body: some View {
        let settings = controller.settings
        let count = Int((upper - lower) / step) + 1
        let kelvin = settings.whiteBalanceAuto ? controller.telemetry.liveTemperature : settings.temperature
        let index = Int(((ExposureMath.clamp(kelvin, lower, upper) - lower) / step).rounded())
        RulerSlider(
            label: settings.whiteBalanceAuto ? "AWB" : "WB",
            fraction: SliderMapping.fraction(index: index, count: count),
            steps: count,
            readout: settings.whiteBalanceAuto ? "AUTO" : ExposureMath.formatKelvin(settings.temperature),
            haptics: controller.haptics,
            onChange: { fraction in
                let newIndex = SliderMapping.index(fraction: fraction, count: count)
                controller.setTemperature(lower + Float(newIndex) * step)
            },
            onLabelTap: {
                controller.resetWhiteBalance()
            }
        )
    }
}

private struct FocusSlider: View {
    let controller: CameraController

    var body: some View {
        let settings = controller.settings
        let position = settings.focusManual ? settings.lensPosition : controller.telemetry.liveLensPosition
        RulerSlider(
            label: settings.focusManual ? "MF" : "AF",
            fraction: Double(position),
            steps: nil,
            readout: String(format: "%.2f", position),
            isEnabled: settings.limits.supportsLockedFocus,
            haptics: controller.haptics
        ) { fraction in
            controller.setLensPosition(Float(fraction))
        }
    }
}

// MARK: - Shutter bar

private struct ShutterBar: View {
    let controller: CameraController

    var body: some View {
        HStack {
            GalleryButton(controller: controller)
            Spacer()
            ShutterButton(status: controller.status) { controller.shutterPressed() }
            Spacer()
            Button {
                controller.toggleGrid()
            } label: {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 24))
                    .foregroundColor(controller.settings.showGrid ? .yellow : .white.opacity(0.8))
                    .frame(width: 50, height: 50)
                    .rotatesWithDevice(controller.telemetry)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.settings.showGrid ? "Hide grid" : "Show grid")
        }
    }
}

private struct GalleryButton: View {
    let controller: CameraController

    var body: some View {
        Button {
            controller.openGallery()
        } label: {
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                if let thumbnail = controller.status.lastThumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .foregroundColor(.white)
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .rotatesWithDevice(controller.telemetry)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Photos")
    }
}
