import SwiftUI

/// The ruler-style scrubber from the original UI, now with detents (F8). With `steps` it snaps to
/// that many positions (a 1/3-stop table, for example) and fires a `detent` haptic on every
/// crossing; reaching either end fires a `limit` haptic once.
struct RulerSlider: View {
    let label: String
    /// Thumb position, 0…1.
    let fraction: Double
    /// Number of snap positions, or nil for a continuous slider.
    let steps: Int?
    let readout: String
    var isEnabled = true
    let haptics: HapticsEngine
    /// Called with the new fraction (already snapped when `steps` is set).
    let onChange: (Double) -> Void
    /// Optional action for tapping the label (e.g. return to auto).
    var onLabelTap: (() -> Void)?

    @State private var lastIndex: Int?
    @State private var atLimit = false

    init(
        label: String,
        fraction: Double,
        steps: Int?,
        readout: String,
        isEnabled: Bool = true,
        haptics: HapticsEngine,
        onChange: @escaping (Double) -> Void,
        onLabelTap: (() -> Void)? = nil
    ) {
        self.label = label
        self.fraction = fraction
        self.steps = steps
        self.readout = readout
        self.isEnabled = isEnabled
        self.haptics = haptics
        self.onChange = onChange
        self.onLabelTap = onLabelTap
    }

    var body: some View {
        HStack(spacing: 15) {
            labelView

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(spacing: geometry.size.width / 20) {
                        ForEach(0..<20, id: \.self) { tick in
                            Rectangle()
                                .fill(Color.white.opacity(tick % 5 == 0 ? 0.6 : 0.3))
                                .frame(width: 1, height: tick % 5 == 0 ? 12 : 6)
                        }
                    }

                    Rectangle()
                        .fill(isEnabled ? Color.yellow : Color.gray)
                        .frame(width: 2, height: 20)
                        .offset(x: min(max(fraction, 0), 1) * geometry.size.width)
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isEnabled, geometry.size.width > 0 else { return }
                            handleDrag(rawFraction: value.location.x / geometry.size.width)
                        }
                        .onEnded { _ in
                            lastIndex = nil
                            atLimit = false
                        }
                )
            }
            .frame(height: 20)

            Text(readout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(isEnabled ? .white : .gray)
                .frame(width: 52, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 20)
        .opacity(isEnabled ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(readout)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = 1.0 / Double(max((steps ?? 51) - 1, 1))
            switch direction {
            case .increment: handleDrag(rawFraction: fraction + step)
            case .decrement: handleDrag(rawFraction: fraction - step)
            @unknown default: break
            }
        }
    }

    @ViewBuilder private var labelView: some View {
        let text = Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.yellow)
            .frame(width: 40, alignment: .leading)
        if let onLabelTap {
            Button(action: onLabelTap) { text }
                .buttonStyle(.plain)
        } else {
            text
        }
    }

    private func handleDrag(rawFraction: Double) {
        let clamped = min(max(rawFraction, 0), 1)
        let hitLimit = rawFraction <= 0 || rawFraction >= 1
        guard let steps, steps > 1 else {
            if hitLimit && !atLimit { haptics.play(.limit) }
            atLimit = hitLimit
            onChange(clamped)
            return
        }
        let index = Int((clamped * Double(steps - 1)).rounded())
        if index != lastIndex {
            if lastIndex != nil {
                if index == 0 || index == steps - 1 {
                    haptics.play(.limit)
                } else {
                    haptics.play(.detent)
                }
            }
            lastIndex = index
            onChange(Double(index) / Double(steps - 1))
        }
    }
}

/// Helpers to map stop tables to slider fractions.
enum SliderMapping {
    static func fraction(index: Int, count: Int) -> Double {
        count > 1 ? Double(index) / Double(count - 1) : 0
    }

    static func index(fraction: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return min(max(Int((fraction * Double(count - 1)).rounded()), 0), count - 1)
    }
}
