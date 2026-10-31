import SwiftUI

/// Keeps a glyph upright while the interface stays in portrait (§9). Reads only the glyph angle,
/// so rotating the phone re-renders just the rotated glyphs.
struct GlyphRotation: ViewModifier {
    let telemetry: LiveTelemetry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(telemetry.glyphAngle))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.25), value: telemetry.glyphAngle)
    }
}

extension View {
    func rotatesWithDevice(_ telemetry: LiveTelemetry) -> some View {
        modifier(GlyphRotation(telemetry: telemetry))
    }
}

struct CapsuleTextButton: View {
    let title: String
    let isSelected: Bool
    let color: Color
    var isStruckThrough = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                .strikethrough(isStruckThrough)
                .foregroundColor(isSelected ? .black : color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? color : Color.clear)
                .overlay(Capsule().stroke(color, lineWidth: 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LensButton: View {
    let lens: LensOption
    let isSelected: Bool
    let action: () -> Void

    private var title: String {
        lens.zoom > 1 ? lens.buttonText + "x" : lens.buttonText
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                .foregroundColor(.white)
                .frame(width: 38, height: 30)
                .background(isSelected ? Color.white.opacity(0.3) : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(lens.buttonText) times lens")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct TextModeButton: View {
    let title: String
    let panel: ControlPanel
    let current: ControlPanel
    let action: (ControlPanel) -> Void

    var body: some View {
        Button {
            action(panel)
        } label: {
            Text(title)
                .font(.system(size: 13, weight: current == panel ? .bold : .medium))
                .foregroundColor(current == panel ? Color(hue: 0.12, saturation: 0.8, brightness: 0.9) : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current == panel ? .isSelected : [])
    }
}

/// The white shutter disc. It dims while the photo output isn't ready (§6.3).
struct ShutterButton: View {
    let status: CaptureStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: 76, height: 76)
                Circle()
                    .stroke(Color.black, lineWidth: 2)
                    .frame(width: 70, height: 70)
            }
            .opacity(status.canCapture ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: status.canCapture)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Take photo")
    }
}
