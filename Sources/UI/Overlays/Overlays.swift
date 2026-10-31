import SwiftUI

/// RGB histogram drawn with `Canvas` (§6.2). Only this view reads `telemetry.histogram`.
struct HistogramView: View {
    let telemetry: LiveTelemetry

    var body: some View {
        let sample = telemetry.histogram
        Canvas { context, size in
            let frame = CGRect(origin: .zero, size: size)
            context.fill(Path(frame), with: .color(.black.opacity(0.4)))
            context.stroke(Path(frame), with: .color(.white), lineWidth: 1)
            guard !sample.isEmpty else { return }
            context.blendMode = .screen
            context.fill(Self.path(for: sample.red, in: size), with: .color(.red.opacity(0.6)))
            context.fill(Self.path(for: sample.green, in: size), with: .color(.green.opacity(0.6)))
            context.fill(Self.path(for: sample.blue, in: size), with: .color(.blue.opacity(0.6)))
        }
        .overlay {
            if sample.isEmpty {
                Text("Histogram")
                    .font(.caption2)
                    .foregroundColor(.white)
            }
        }
        .accessibilityHidden(true)
    }

    static func path(for bins: [Float], in size: CGSize) -> Path {
        Path { path in
            guard !bins.isEmpty else { return }
            let step = size.width / CGFloat(bins.count)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                let y = size.height - CGFloat(value) * size.height * 0.95
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }
}

/// Rule-of-thirds grid with a world-horizontal level line (gravity based, works in any orientation).
struct GridOverlayView: View {
    let telemetry: LiveTelemetry

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                        path.move(to: CGPoint(x: width * fraction, y: 0))
                        path.addLine(to: CGPoint(x: width * fraction, y: height))
                        path.move(to: CGPoint(x: 0, y: height * fraction))
                        path.addLine(to: CGPoint(x: width, y: height * fraction))
                    }
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 1)

                LevelLine(telemetry: telemetry)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }
}

private struct LevelLine: View {
    let telemetry: LiveTelemetry

    var body: some View {
        let roll = telemetry.rollDegrees
        let isLevel = abs(RotationMath.deviationFromNearestRightAngle(roll)) < 1.0
        Rectangle()
            .fill(isLevel ? Color.green : Color.yellow)
            .frame(width: 100, height: 2)
            .rotationEffect(.degrees(-roll))
    }
}

/// Tap-to-focus box.
struct FocusBoxView: View {
    let status: CaptureStatus

    var body: some View {
        if let indicator = status.focusIndicator {
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .frame(width: 60, height: 60)
                .position(indicator.point)
                .id(indicator.id)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

/// White screen flash tied to the real exposure (`willCapturePhoto`), not the button press.
struct CaptureFlashView: View {
    let status: CaptureStatus
    @State private var opacity: Double = 0

    init(status: CaptureStatus) {
        self.status = status
    }

    var body: some View {
        Color.white
            .opacity(opacity)
            .allowsHitTesting(false)
            .onChange(of: status.flashCounter) { _, _ in
                withAnimation(.linear(duration: 0.04)) {
                    opacity = 0.9
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    withAnimation(.easeOut(duration: 0.22)) {
                        opacity = 0
                    }
                }
            }
    }
}

/// Banners for permissions, storage, failed saves and session errors (§11).
struct BannerStack: View {
    let status: CaptureStatus
    let onAction: (Banner) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(status.banners) { banner in
                HStack(spacing: 10) {
                    Text(banner.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let title = banner.actionTitle {
                        Button(title) { onAction(banner) }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.yellow)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
        .animation(.easeInOut(duration: 0.2), value: status.banners)
    }
}

/// Dimmed, blurred preview while the session is interrupted.
struct InterruptionOverlay: View {
    let status: CaptureStatus

    var body: some View {
        if let reason = status.interruption {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.35)
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 28))
                    Text(reason)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            .transition(.opacity)
        }
    }
}

/// Full-screen message when camera access is denied or restricted.
struct PermissionView: View {
    let authorization: CameraAuthorization
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.8))
            Text(authorization == .restricted ? "Camera access is restricted" : "Camera access is off")
                .font(.headline)
                .foregroundColor(.white)
            Text("Allow camera access in Settings to use ManualCameraApp.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if authorization == .denied {
                Button("Open Settings", action: openSettings)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.white, in: Capsule())
                    .foregroundColor(.black)
            }
        }
        .padding(32)
    }
}

#if DEBUG
/// Debug-only readout of feed fps, UI fps and the last press→capture latency (§10).
struct DebugHUD: View {
    let telemetry: LiveTelemetry

    var body: some View {
        Text(String(format: "feed %.0f · ui %.0f · lag %.0fms", telemetry.feedFPS, telemetry.uiFPS, telemetry.lastLatencyMS))
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.green)
            .padding(4)
            .background(Color.black.opacity(0.5))
            .allowsHitTesting(false)
    }
}
#endif
