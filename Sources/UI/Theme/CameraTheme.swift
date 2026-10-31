import SwiftUI

/// How each component draws itself. Screens never branch on the theme; components render through
/// these styles, so the Medium Format Edition swaps the theme, not the screens (Slice 2 §3).
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
  /// Selection colour (Sony orange in the Pro theme).
  var accent: Color
  var text: Color
  var secondaryText: Color
  var hairline: Color
  var warning: Color
  var clip: Color
  /// Focus lock and level confirmation colour (Sony green).
  var focusGreen: Color
  /// Emphasis by inversion (black on white) instead of an accent colour.
  var emphasisByInversion: Bool

  // Type
  var telemetryFont: Font
  var telemetryLargeFont: Font
  /// Primary exposure read-outs in the minimal strip (the Edition's large, light numbers).
  var readoutFont: Font
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
  /// Whether Fn tiles show their current value. Every value appears in exactly one place: the Pro
  /// theme shows exposure values on the Fn bar; the Edition shows them large in the strip.
  var tilesShowValues: Bool

  /// Selection: dial index, chosen option, selected lens, MF marker.
  var selection: Color { emphasisByInversion ? text : accent }
  /// Confirmation: focus locked, camera level.
  var confirmation: Color { emphasisByInversion ? text : focusGreen }

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
    focusGreen: Color(hex: 0x00E65C),
    emphasisByInversion: false,
    telemetryFont: .system(size: 14, weight: .medium, design: .monospaced),
    telemetryLargeFont: .system(size: 15, weight: .medium, design: .monospaced),
    readoutFont: .system(size: 15, weight: .medium, design: .monospaced),
    labelFont: .system(size: 11, weight: .semibold, design: .default),
    labelTracking: 0.44,
    tileCornerRadius: 8,
    badgeCornerRadius: 3,
    tileHeight: 50,
    trayHeight: 92,
    stripHeight: 58,
    trayAnimation: .spring(response: 0.28, dampingFraction: 0.86),
    pressAnimation: .easeOut(duration: 0.12),
    dial: .drum,
    tile: .filled,
    badge: .accentOutline,
    shutter: .ring,
    telemetry: .dense,
    tiles: FnTile.allCases,
    tilesShowValues: true
  )

  /// The Medium Format Edition (Slice 3 §4): calm and monochrome, emphasis by inversion, large
  /// light read-outs, an arc dial and five tiles (WB and focus live in the Fn sheet).
  static let edition = CameraTheme(
    id: .edition,
    background: Color(hex: 0x0A0A0A),
    surface: Color(hex: 0x141414),
    surfaceRaised: Color(hex: 0x1E1E1E),
    accent: Color(hex: 0xF2F2F2),
    text: Color(hex: 0xF2F2F2),
    secondaryText: Color(hex: 0xF2F2F2, opacity: 0.55),
    hairline: Color.white.opacity(0.18),
    warning: Color(hex: 0xE8C468),
    clip: Color(hex: 0xF2F2F2),
    focusGreen: Color(hex: 0xF2F2F2),
    emphasisByInversion: true,
    telemetryFont: .system(size: 13, weight: .regular, design: .default),
    telemetryLargeFont: .system(size: 15, weight: .regular, design: .default),
    readoutFont: .system(size: 30, weight: .light, design: .default),
    labelFont: .system(size: 11, weight: .regular, design: .default),
    labelTracking: 0.88,
    tileCornerRadius: 4,
    badgeCornerRadius: 4,
    tileHeight: 40,
    trayHeight: 92,
    stripHeight: 92,
    trayAnimation: .easeInOut(duration: 0.3),
    pressAnimation: .easeOut(duration: 0.12),
    dial: .rotary,
    tile: .minimal,
    badge: .inverted,
    shutter: .flatDisc,
    telemetry: .minimal,
    tiles: [.mode, .aperture, .shutter, .iso, .ev],
    tilesShowValues: false
  )

  static func theme(for id: ThemeID) -> CameraTheme {
    switch id {
    case .alpha: return .alpha
    case .edition: return .edition
    }
  }
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
