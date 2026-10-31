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
      .fill(telemetry.rollIsLevel ? theme.confirmation : Color.white.opacity(0.6))
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
    guard crosshairLength > 0 else { return path }
    let mid = CGPoint(x: rect.midX, y: rect.midY)
    path.move(to: CGPoint(x: mid.x - crosshairLength, y: mid.y))
    path.addLine(to: CGPoint(x: mid.x + crosshairLength, y: mid.y))
    path.move(to: CGPoint(x: mid.x, y: mid.y - crosshairLength))
    path.addLine(to: CGPoint(x: mid.x, y: mid.y + crosshairLength))

    return path
  }
}

/// The focus frame, like an Alpha body's flexible spot: it always shows where the camera focuses
/// (the centre until you tap elsewhere; long-press returns it to the centre), turns to the
/// confirmation colour when focus is achieved, and is hidden in MF, where the loupe takes over.
struct FocusFrameView: View {
  let status: CaptureStatus
  let focusMode: FocusMode
  @Environment(\.cameraTheme) var theme
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State private var pop: CGFloat = 1

  private let boxSize: CGFloat = 64

  var body: some View {
    GeometryReader { geometry in
      let point = Self.position(uv: status.focusPointUV, geometry: status.viewfinder, in: geometry.size)
      let state = status.focusState
      let locked = state == .locked
      let color: Color = locked ? theme.confirmation : Color.white.opacity(state == .searching ? 1 : 0.82)

      ZStack {
        SonyFocusReticleShape(cornerLength: 12, crosshairLength: 0)
          .stroke(color, style: StrokeStyle(lineWidth: locked ? 2.25 : 1.5, lineCap: .square))
          .shadow(color: Color.black.opacity(0.45), radius: 1.5, x: 0, y: 0.5)
          .frame(width: boxSize, height: boxSize)
        // Centre dot: the AF point itself.
        Circle()
          .fill(color)
          .frame(width: 3, height: 3)
          .shadow(color: Color.black.opacity(0.45), radius: 1, x: 0, y: 0.5)
      }
      .scaleEffect(pop)
      .position(point)
      .opacity(focusMode == .manual ? 0 : 1)
      .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: point)
      .animation(.easeOut(duration: 0.15), value: state)
      .animation(.easeOut(duration: 0.2), value: focusMode)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onChange(of: status.focusTapID) { _, _ in
      guard !reduceMotion else { return }
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) { pop = 1.18 }
      DispatchQueue.main.async {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { pop = 1 }
      }
    }
  }

  /// The frame's centre in this view: the focus point mapped into the video rect, or the centre.
  static func position(uv: CGPoint?, geometry: ViewfinderGeometry, in size: CGSize) -> CGPoint {
    let video = geometry.videoRect.width > 0 && geometry.videoRect.height > 0
      ? geometry.videoRect
      : CGRect(origin: .zero, size: size)
    guard let uv else { return CGPoint(x: video.midX, y: video.midY) }
    return CGPoint(x: video.minX + uv.x * video.width, y: video.minY + uv.y * video.height)
  }
}

/// Edition framing (Slice 3 §5): everything outside the 1:1 or XPAN frame is dimmed to 88% black,
/// with a hairline on the frame edge. The developed photo is cropped to the same rect.
struct FramingMatteView: View {
  let framing: FramingMode
  @Environment(\.cameraTheme) var theme

  var body: some View {
    GeometryReader { geometry in
      let size = geometry.size
      let crop = FramingMath.cropRect(for: framing, in: size)
      ZStack {
        MatteShape(hole: crop)
          .fill(Color.black.opacity(0.88), style: FillStyle(eoFill: true))
        Rectangle()
          .stroke(theme.hairline, lineWidth: 1)
          .frame(width: crop.width, height: crop.height)
          .position(x: crop.midX, y: crop.midY)
      }
      .opacity(framing == .native ? 0 : 1)
      .animation(.easeInOut(duration: 0.3), value: framing)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// The full rect minus an animatable hole (even-odd fill), so the matte slides between framings.
private struct MatteShape: Shape {
  var hole: CGRect

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
    set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.addRect(rect)
    path.addRect(hole)
    return path
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
              .foregroundColor(theme.selection)
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
