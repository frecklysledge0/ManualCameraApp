import SwiftUI

/// The manual-focus wheel (Slice 2 §8). Finger travel maps to lens position with a
/// velocity-dependent gain (`FocusMath`); the bar underneath shows MFD ←→ ∞.
struct MFWheel: View {
    let position: Float
    let onBegan: () -> Void
    /// (points moved since the last event, finger speed in points per second)
    let onMoved: (Double, Double) -> Void
    let onEnded: () -> Void

    @Environment(\.cameraTheme) var theme
    @State var lastTranslation: CGFloat?
    @State var phase: CGFloat = 0

    init(position: Float, onBegan: @escaping () -> Void, onMoved: @escaping (Double, Double) -> Void, onEnded: @escaping () -> Void) {
        self.position = position
        self.onBegan = onBegan
        self.onMoved = onMoved
        self.onEnded = onEnded
    }

    var body: some View {
        VStack(spacing: 6) {
            WheelRidges(phase: phase, color: theme.text)
                .frame(height: 36)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: theme.tileCornerRadius))
                .overlay(RoundedRectangle(cornerRadius: theme.tileCornerRadius).stroke(theme.hairline, lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if lastTranslation == nil {
                                lastTranslation = 0
                                onBegan()
                            }
                            let delta = value.translation.width - (lastTranslation ?? 0)
                            lastTranslation = value.translation.width
                            guard delta != 0 else { return }
                            phase += delta
                            onMoved(Double(delta), Double(abs(value.velocity.width)))
                        }
                        .onEnded { _ in
                            lastTranslation = nil
                            onEnded()
                        }
                )

            FocusDistanceBar(position: position)
                .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Manual focus")
        .accessibilityValue(String(format: "%.0f percent towards infinity", Double(position) * 100))
        .accessibilityAdjustableAction { direction in
            onBegan()
            switch direction {
            case .increment: onMoved(20, 0)
            case .decrement: onMoved(-20, 0)
            @unknown default: break
            }
            onEnded()
        }
    }
}

private struct WheelRidges: View {
    let phase: CGFloat
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 7
            var x = phase.truncatingRemainder(dividingBy: spacing)
            if x < 0 { x += spacing }
            while x < size.width {
                // Ridges fade towards the edges, like a cylinder.
                let t = abs(x / size.width - 0.5) * 2
                let rect = CGRect(x: x, y: 6, width: 1, height: size.height - 12)
                context.fill(Path(rect), with: .color(color.opacity(0.55 * (1 - t * t))))
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// MFD ←→ ∞ with the current lens position.
struct FocusDistanceBar: View {
    let position: Float
    @Environment(\.cameraTheme) var theme

    var body: some View {
        HStack(spacing: 6) {
            ThemeLabel("MFD")
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.hairline).frame(height: 2)
                    Capsule()
                        .fill(theme.emphasis)
                        .frame(width: 3, height: 10)
                        .offset(x: CGFloat(ExposureMath.clamp(position, 0, 1)) * max(geometry.size.width - 3, 0))
                }
                .frame(maxHeight: .infinity)
            }
            ThemeLabel("∞")
        }
        .accessibilityHidden(true)
    }
}
