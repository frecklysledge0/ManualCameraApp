import SwiftUI

/// Root view (Slice 2 §4): telemetry strip, the 4:3 viewfinder with nothing drawn over it except
/// opt-in overlays and the loupe, then the dial tray, the Quick Fn bar and the shutter row.
/// It reads only rarely-changing state; per-frame values live in leaf views.
struct CameraView: View {
    let controller: CameraController
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        let theme = CameraTheme.alpha
        ZStack {
            theme.background.ignoresSafeArea()

            switch controller.status.authorization {
            case .denied, .restricted:
                PermissionView(authorization: controller.status.authorization) {
                    controller.perform(.openSettings, for: .noCamera)
                }
            case .unknown, .authorized:
                CameraLayout(controller: controller)
            }
        }
        .environment(\.cameraTheme, theme)
        .onAppear {
            controller.start()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: controller.sceneBecameActive()
            case .background: controller.sceneEnteredBackground()
            default: break
            }
        }
    }
}

private struct CameraLayout: View {
    let controller: CameraController
    @Environment(\.cameraTheme) var theme
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Height of the shutter row.
    private let shutterRowHeight: CGFloat = 92

    var body: some View {
        GeometryReader { geometry in
            let deck = theme.trayHeight + theme.tileHeight + shutterRowHeight + 16
            let available = geometry.size.height - theme.stripHeight - deck
            // The viewfinder is 3:4 and never shrinks the controls: on short screens it gets
            // narrower instead of being covered.
            let viewfinderWidth = min(geometry.size.width, max(available, 0) * 3 / 4)
            let viewfinderHeight = viewfinderWidth * 4 / 3

            VStack(spacing: 0) {
                TelemetryStrip(controller: controller)
                    .frame(height: theme.stripHeight)

                ViewfinderLayer(controller: controller)
                    .frame(width: viewfinderWidth, height: viewfinderHeight)
                    .clipped()
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Color.clear.frame(height: theme.trayHeight)
                        if let tile = controller.settings.activeTile {
                            DialTray(controller: controller, tile: tile)
                                .id(tile)
                                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        } else {
                            BannerStack(status: controller.status) { banner in
                                controller.perform(banner.action, for: banner.kind)
                            }
                            .frame(maxHeight: theme.trayHeight, alignment: .bottom)
                        }
                    }
                    .clipped()

                    FnBar(controller: controller)

                    ShutterRow(controller: controller)
                        .frame(height: shutterRowHeight)
                }
                .padding(.bottom, 4)
            }
        }
        .sheet(isPresented: Binding(
            get: { controller.settings.showFnSheet },
            set: { if !$0 && controller.settings.showFnSheet { controller.toggleFnSheet() } }
        )) {
            FnSheet(controller: controller)
                .presentationDetents([.medium, .large])
                .presentationBackground(theme.surface)
                .environment(\.cameraTheme, theme)
        }
    }
}

/// The camera image and the opt-in overlays drawn over it.
private struct ViewfinderLayer: View {
    let controller: CameraController

    var body: some View {
        let overlays = controller.settings.overlays
        ZStack {
            CameraPreviewView(controller: controller)

            if overlays.grid != .off {
                GridOverlayView(mode: overlays.grid)
            }
            if overlays.levelLine {
                HorizonLineView(telemetry: controller.telemetry)
            }

            FocusFrameView(status: controller.status)

            InterruptionOverlay(status: controller.status)

            CaptureFlashView(status: controller.status)

            #if DEBUG
            DebugHUD(telemetry: controller.telemetry)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(4)
            #endif
        }
    }
}

private struct ShutterRow: View {
    let controller: CameraController

    var body: some View {
        HStack {
            GalleryButton(controller: controller)
                .frame(width: 90)
            Spacer()
            ShutterButton(status: controller.status) {
                controller.shutterPressed()
            }
            Spacer()
            LensSelector(controller: controller)
                .frame(width: 120)
        }
        .padding(.horizontal, 16)
    }
}
