import SwiftUI

/// How each component draws itself. Screens never branch on the theme; components render through
/// these styles, so Slice 3's Edition swaps the theme, not the screens (Slice 2 §3).
enum DialStyle: Sendable { case drum, rotary }
enum TileStyle: Sendable { case filled, minimal }
enum BadgeStyle: Sendable { case accentOutline, inverted }
enum ShutterButtonStyle: Sendable { case ring, flatDisc }
enum TelemetryStyle: Sendable { case dense, minimal }

struct CameraTheme {
  var id: ThemeID

  // Colour tokens
  var background: Color
  var surface: Color
  var surfaceRaised: Color
  var accent: Color
  var text: Color
  var secondaryText: Color
  var hairline: Color
  var warning: Color
  var clip: Color
  /// Focus lock and level indicator confirmation colour (Sony emerald green).
  var focusGreen: Color
  /// Emphasis by inversion (black on white) instead of an accent colour.
  var emphasisByInversion: Bool

  // Type
  var telemetryFont: Font
  var telemetryLargeFont: Font
  var labelFont: Font
  var labelTracking: CGFloat

  // Metrics
  var tileCornerRadius: CGFloat
  var badgeCornerRadius: CGFloat
  var tileHeight: CGFloat
  var trayHeight: CGFloat
  var stripHeight: CGFloat

  // Motion
  var trayAnimation: Animation
  var pressAnimation: Animation

  // Component styles
  var dial: DialStyle
  var tile: TileStyle
  var badge: BadgeStyle
  var shutter: ShutterButtonStyle
  var telemetry: TelemetryStyle

  /// Fn bar tiles shown by this theme.
  var tiles: [FnTile]

  /// Emphasis colour for focus lock and level states.
  var emphasis: Color { emphasisByInversion ? text : focusGreen }

  /// The Alpha-inspired pro theme (Slice 2 §3).
  static let alpha = CameraTheme(
    id: .alpha,
    background: Color(hex: 0x000000),
    surface: Color(hex: 0x111214),
    surfaceRaised: Color(hex: 0x1B1C1F),
    accent: Color(hex: 0xFF5500),
    text: Color.white.opacity(0.92),
    secondaryText: Color.white.opacity(0.60),
    hairline: Color.white.opacity(0.14),
    warning: Color(hex: 0xFFC400),
    clip: Color(hex: 0xFF3B30),
    focusGreen: Color(hex: 0x00FF66),
    emphasisByInversion: false,
    telemetryFont: .system(size: 14, weight: .medium, design: .monospaced),
    telemetryLargeFont: .system(size: 15, weight: .medium, design: .monospaced),
    labelFont: .system(size: 11, weight: .semibold, design: .default),
    labelTracking: 0.44,
    tileCornerRadius: 8,
    badgeCornerRadius: 3,
    tileHeight: 50,
    trayHeight: 78,
    stripHeight: 58,
    trayAnimation: .spring(response: 0.28, dampingFraction: 0.86),
    pressAnimation: .easeOut(duration: 0.12),
    dial: .drum,
    tile: .filled,
    badge: .accentOutline,
    shutter: .ring,
    telemetry: .dense,
    tiles: FnTile.allCases
  )
}

/// The Quick Fn bar tiles (Slice 2 §4).
enum FnTile: String, CaseIterable, Sendable {
  case mode
  case aperture
  case shutter
  case iso
  case ev
  case whiteBalance
  case focus

  var label: String {
    switch self {
    case .mode: return "MODE"
    case .aperture: return "F"
    case .shutter: return "SS"
    case .iso: return "ISO"
    case .ev: return "EV"
    case .whiteBalance: return "WB"
    case .focus: return "FOCUS"
    }
  }
}

private struct CameraThemeKey: EnvironmentKey {
  static let defaultValue = CameraTheme.alpha
}

extension EnvironmentValues {
  var cameraTheme: CameraTheme {
    get { self[CameraThemeKey.self] }
    set { self[CameraThemeKey.self] = newValue }
  }
}

extension Color {
  /// `Color(hex: 0xFF5500)`
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }
}

/// Theme-aware label text: uppercase, tracked, honours Bold Text.
struct ThemeLabel: View {
  let text: String
  var color: Color?
  @Environment(\.cameraTheme) var theme
  @Environment(\.legibilityWeight) var legibilityWeight

  init(_ text: String, color: Color? = nil) {
    self.text = text
    self.color = color
  }

  var body: some View {
    Text(text.uppercased())
      .font(theme.labelFont)
      .fontWeight(legibilityWeight == .bold ? .bold : nil)
      .tracking(theme.labelTracking)
      .foregroundColor(color ?? theme.secondaryText)
  }
}
