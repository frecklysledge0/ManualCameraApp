import SwiftUI

/// Root view (Slice 2 §4): telemetry strip, the 4:3 viewfinder with nothing drawn over it except
/// opt-in overlays and the loupe, then the dial tray, the Quick Fn bar and the shutter row.
/// It reads only rarely-changing state; per-frame values live in leaf views.
struct CameraView: View {
    let controller: CameraController
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        // The theme follows the settings; `setEdition` changes it inside a 0.35 s animation, so
        // every colour and metric cross-dissolves.
        let theme = CameraTheme.theme(for: controller.settings.theme)
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
        // The strip shows battery and shots left like a camera body; the system bar would repeat them.
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
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
    private let shutterRowHeight: CGFloat = 88

    var body: some View {
        GeometryReader { geometry in
            // Fixed controls: strip, Fn bar and shutter row. The 3:4 viewfinder takes the rest at
            // full width when it fits, and gets narrower on short screens; the controls never shrink.
            let fixed = theme.stripHeight + theme.tileHeight + shutterRowHeight + 12
            let region = max(geometry.size.height - fixed, 0)
            let viewfinderWidth = min(geometry.size.width, region * 3 / 4)
            let viewfinderHeight = viewfinderWidth * 4 / 3

            VStack(spacing: 0) {
                TelemetryStrip(controller: controller)
                    .frame(height: theme.stripHeight)

                // The dial tray and banners rise from the bottom of this region. Where the screen
                // has room they sit below the image; on shorter phones they cover its lower edge
                // only while open, like a camera body's on-screen menu.
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        ViewfinderLayer(controller: controller)
                            .frame(width: viewfinderWidth, height: viewfinderHeight)
                            .clipped()
                            .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    }

                    Group {
                        if let tile = controller.settings.activeTile {
                            DialTray(controller: controller, tile: tile)
                                .id(tile)
                                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                        } else {
                            BannerStack(status: controller.status) { banner in
                                controller.perform(banner.action, for: banner.kind)
                            }
                            .padding(.bottom, 8)
                        }
                    }
                    .frame(maxHeight: theme.trayHeight, alignment: .bottom)
                }
                .frame(height: region)
                .clipped()

                VStack(spacing: 4) {
                    FnBar(controller: controller)
                        .padding(.top, 4)

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
        let settings = controller.settings
        let overlays = settings.overlays
        ZStack {
            CameraPreviewView(controller: controller)

            if settings.isEdition {
                FramingMatteView(framing: settings.framing)
            }

            if overlays.grid != .off {
                GridOverlayView(mode: overlays.grid)
            }
            if overlays.levelLine {
                HorizonLineView(telemetry: controller.telemetry)
            }

            FocusFrameView(status: controller.status, focusMode: settings.focusMode)

            InterruptionOverlay(status: controller.status)

            CaptureFlashView(status: controller.status)

            #if DEBUG
            if settings.showPerformanceHUD {
                DebugHUD(telemetry: controller.telemetry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(4)
            }
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
