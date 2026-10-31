import SwiftUI

/// Grid overlay: rule of thirds or a centred square (Slice 2 §4). Opt-in only.
struct GridOverlayView: View {
  let mode: GridMode
  @Environment(\.cameraTheme) var theme

  var body: some View {
    Canvas { context, size in
      var path = Path()
      switch mode {
      case .off:
        return
      case .thirds:
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
          path.move(to: CGPoint(x: size.width * fraction, y: 0))
          path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
          path.move(to: CGPoint(x: 0, y: size.height * fraction))
          path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
        }
      case .square:
        let side = min(size.width, size.height)
        path.addRect(
          CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        )
      }
      context.stroke(path, with: .color(.white.opacity(0.45)), lineWidth: 0.75)
    }
    .allowsHitTesting(false)
  }
}

/// Optional thin horizon line over the viewfinder (Slice 2 §9).
struct HorizonLineView: View {
  let telemetry: LiveTelemetry
  @Environment(\.cameraTheme) var theme

  var body: some View {
    let roll = telemetry.rollDegrees
    Rectangle()
      .fill(telemetry.rollIsLevel ? theme.emphasis : Color.white.opacity(0.6))
      .frame(width: 160, height: 1)
      .rotationEffect(.degrees(-roll))
      .allowsHitTesting(false)
  }
}

/// Sony Alpha focus reticle shape with 4 corner brackets and a subtle center crosshair.
struct SonyFocusReticleShape: Shape {
  var cornerLength: CGFloat = 10
  var crosshairLength: CGFloat = 4

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let x = rect.minX
    let y = rect.minY
    let w = rect.width
    let h = rect.height
    let len = min(cornerLength, min(w, h) / 2)

    // Top-left
    path.move(to: CGPoint(x: x, y: y + len))
    path.addLine(to: CGPoint(x: x, y: y))
    path.addLine(to: CGPoint(x: x + len, y: y))

    // Top-right
    path.move(to: CGPoint(x: x + w - len, y: y))
    path.addLine(to: CGPoint(x: x + w, y: y))
    path.addLine(to: CGPoint(x: x + w, y: y + len))

    // Bottom-left
    path.move(to: CGPoint(x: x, y: y + h - len))
    path.addLine(to: CGPoint(x: x, y: y + h))
    path.addLine(to: CGPoint(x: x + len, y: y + h))

    // Bottom-right
    path.move(to: CGPoint(x: x + w - len, y: y + h))
    path.addLine(to: CGPoint(x: x + w, y: y + h))
    path.addLine(to: CGPoint(x: x + w, y: y + h - len))

    // Center crosshair
    let mid = CGPoint(x: rect.midX, y: rect.midY)
    path.move(to: CGPoint(x: mid.x - crosshairLength, y: mid.y))
    path.addLine(to: CGPoint(x: mid.x + crosshairLength, y: mid.y))
    path.move(to: CGPoint(x: mid.x, y: mid.y - crosshairLength))
    path.addLine(to: CGPoint(x: mid.x, y: mid.y + crosshairLength))

    return path
  }
}

/// Sony-style focus frame: stays at center in AF (like Sony Alpha Center Area),
/// moves to tapped point on tap-to-focus, and turns bright emerald green when locked.
struct FocusFrameView: View {
  let status: CaptureStatus
  @Environment(\.cameraTheme) var theme

  private let boxSize: CGFloat = 58

  var body: some View {
    GeometryReader { geometry in
      let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
      let point = status.focusIndicator?.point ?? center
      let isLocked = status.focusIndicator?.locked ?? false
      let isTapped = status.focusIndicator != nil

      ZStack {
        // Subtle corner brackets + crosshair
        SonyFocusReticleShape(cornerLength: 10, crosshairLength: isLocked ? 5 : 4)
          .stroke(
            isLocked ? theme.emphasis : Color.white.opacity(isTapped ? 0.95 : 0.70),
            lineWidth: isLocked ? 2 : 1.25
          )
          .shadow(color: Color.black.opacity(0.4), radius: 1, x: 0, y: 1)
          .frame(width: boxSize, height: boxSize)

        // When locked: subtle green confirmation border
        if isLocked {
          RoundedRectangle(cornerRadius: 2)
            .stroke(theme.emphasis, lineWidth: 1.5)
            .frame(width: boxSize - 4, height: boxSize - 4)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .position(point)
      .animation(.spring(response: 0.25, dampingFraction: 0.75), value: point)
      .animation(.easeOut(duration: 0.15), value: isLocked)
      .allowsHitTesting(false)
    }
  }
}

/// Screen flash tied to the real exposure (`willCapturePhoto`), not the button press.
struct CaptureFlashView: View {
  let status: CaptureStatus
  @State var opacity: Double = 0

  init(status: CaptureStatus) {
    self.status = status
  }

  var body: some View {
    Color.black
      .opacity(opacity)
      .allowsHitTesting(false)
      .onChange(of: status.flashCounter) { _, _ in
        withAnimation(.linear(duration: 0.03)) {
          opacity = 0.85
        }
        Task { @MainActor in
          try? await Task.sleep(nanoseconds: 60_000_000)
          withAnimation(.easeOut(duration: 0.18)) {
            opacity = 0
          }
        }
      }
  }
}

/// Dimmed, blurred preview while the session is interrupted (Slice 1 §11).
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
      .allowsHitTesting(false)
    }
  }
}

/// Banners for permissions, storage, failed saves and session errors (Slice 1 §11).
struct BannerStack: View {
  let status: CaptureStatus
  let onAction: (Banner) -> Void
  @Environment(\.cameraTheme) var theme

  init(status: CaptureStatus, onAction: @escaping (Banner) -> Void) {
    self.status = status
    self.onAction = onAction
  }

  var body: some View {
    VStack(spacing: 6) {
      ForEach(status.banners) { banner in
        HStack(spacing: 10) {
          Text(banner.message)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(theme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
          if let title = banner.actionTitle {
            Button(title) { onAction(banner) }
              .font(.system(size: 12, weight: .bold))
              .foregroundColor(theme.emphasis)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.surfaceRaised.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .padding(.horizontal, 12)
    .animation(.easeInOut(duration: 0.2), value: status.banners)
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
      Text("Allow camera access in Settings to use \(Branding.appName).")
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
  /// Debug-only readout of feed fps, UI fps and the last press→capture latency (Slice 1 §10).
  struct DebugHUD: View {
    let telemetry: LiveTelemetry

    var body: some View {
      Text(
        String(
          format: "feed %.0f · ui %.0f · lag %.0fms", telemetry.feedFPS, telemetry.uiFPS,
          telemetry.lastLatencyMS)
      )
      .font(.system(size: 9, design: .monospaced))
      .foregroundColor(.green)
      .padding(3)
      .background(Color.black.opacity(0.5))
      .allowsHitTesting(false)
    }
  }
#endif
