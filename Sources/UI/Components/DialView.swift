import SwiftUI

/// One position on a dial.
struct DialStop: Equatable, Sendable {
    /// Text drawn under major ticks (nil for minor ticks).
    var label: String?
    var isMajor: Bool
}

/// The drum dial (Slice 2 §5): drag 1:1, fling with deceleration that snaps to a detent, a
/// `detent` haptic on every crossing, a rubber band and a `limit` haptic at the ends, and a
/// double-tap for AUTO. Ticks are drawn once in `DialStrip` and only translated while turning,
/// so the dial holds 120 Hz. Slice 3's Edition draws the same dial as an arc (`DialStyle.rotary`).
struct DialView: View {
    let stops: [DialStop]
    let selectedIndex: Int
    var isEnabled = true
    /// Shows AUTO over the dial (the parameter is chosen by the camera).
    var isAuto = false
    let accessibilityName: String
    let haptics: HapticsEngine
    let onSelect: (Int) -> Void
    var onAuto: (() -> Void)?

    @Environment(\.cameraTheme) var theme
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// Fractional index while the user is turning or the dial is coasting; nil = follow `selectedIndex`.
    @State var position: Double?
    @State var dragOrigin: Double?
    @State var lastIndex: Int?
    @State var flingTask: Task<Void, Never>?

    private let spacing: CGFloat = 16

    init(
        stops: [DialStop],
        selectedIndex: Int,
        isEnabled: Bool = true,
        isAuto: Bool = false,
        accessibilityName: String,
        haptics: HapticsEngine,
        onSelect: @escaping (Int) -> Void,
        onAuto: (() -> Void)? = nil
    ) {
        self.stops = stops
        self.selectedIndex = selectedIndex
        self.isEnabled = isEnabled
        self.isAuto = isAuto
        self.accessibilityName = accessibilityName
        self.haptics = haptics
        self.onSelect = onSelect
        self.onAuto = onAuto
    }

    private var maxIndex: Int { max(stops.count - 1, 0) }
    private var displayedPosition: Double { position ?? Double(min(max(selectedIndex, 0), maxIndex)) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                if theme.dial == .rotary {
                    RotaryDialFace(stops: stops, position: displayedPosition, spacingDegrees: 6, theme: theme)
                        .opacity(isAuto ? 0.45 : 1)
                } else {
                    DialStrip(stops: stops, spacing: spacing, text: theme.text, secondary: theme.secondaryText, font: theme.labelFont)
                        .equatable()
                        .frame(width: CGFloat(maxIndex) * spacing + width, height: geometry.size.height)
                        .offset(x: -CGFloat(displayedPosition) * spacing)
                        .frame(width: width, height: geometry.size.height, alignment: .leading)
                        .clipped()
                        .opacity(isAuto ? 0.45 : 1)
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.18),
                                    .init(color: .black, location: 0.82),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }

                // Centre index, aligned with the ticks (which hang from the top edge).
                VStack(spacing: 0) {
                    DialIndexMarker(color: theme.selection)
                        .frame(width: 9, height: 5)
                    Rectangle()
                        .fill(theme.selection)
                        .frame(width: 2, height: theme.dial == .rotary ? 14 : 18)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 1)
                .allowsHitTesting(false)

                if isAuto {
                    // Below the labels so it never covers the index or the selected value.
                    Text("AUTO")
                        .font(theme.labelFont.weight(.bold))
                        .tracking(theme.labelTracking)
                        .foregroundColor(theme.emphasisByInversion ? theme.background : theme.selection)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            theme.emphasisByInversion ? theme.text : theme.background.opacity(0.75),
                            in: RoundedRectangle(cornerRadius: theme.badgeCornerRadius)
                        )
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(TapGesture(count: 2).onEnded { onAuto?() })
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(isAuto ? "Auto" : (stops.indices.contains(selectedIndex) ? (stops[selectedIndex].label ?? "\(selectedIndex)") : ""))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: step(to: selectedIndex + 1)
            case .decrement: step(to: selectedIndex - 1)
            @unknown default: break
            }
        }
        .onDisappear {
            flingTask?.cancel()
        }
    }

    // MARK: - Interaction

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard isEnabled, !stops.isEmpty else { return }
                if dragOrigin == nil {
                    flingTask?.cancel()
                    dragOrigin = displayedPosition
                    lastIndex = Int(displayedPosition.rounded())
                }
                let raw = (dragOrigin ?? 0) - Double(value.translation.width / spacing)
                position = rubberBanded(raw)
                report(Int(min(max(raw, 0), Double(maxIndex)).rounded()))
            }
            .onEnded { value in
                guard isEnabled, !stops.isEmpty else { return }
                dragOrigin = nil
                let velocity = -Double(value.velocity.width / spacing) // stops per second
                if abs(velocity) > 4, !reduceMotion {
                    fling(from: min(max(displayedPosition, 0), Double(maxIndex)), velocity: velocity)
                } else {
                    settle(at: Int(min(max(displayedPosition, 0), Double(maxIndex)).rounded()))
                }
            }
    }

    /// Resistance past either end (rubber band).
    private func rubberBanded(_ raw: Double) -> Double {
        if raw < 0 { return raw * 0.3 }
        if raw > Double(maxIndex) { return Double(maxIndex) + (raw - Double(maxIndex)) * 0.3 }
        return raw
    }

    private func report(_ index: Int) {
        guard index != lastIndex else { return }
        lastIndex = index
        haptics.play(index == 0 || index == maxIndex ? .limit : .detent)
        onSelect(index)
    }

    private func step(to index: Int) {
        guard stops.indices.contains(index) else {
            haptics.play(.limit)
            return
        }
        lastIndex = index
        haptics.play(.detent)
        onSelect(index)
    }

    private func settle(at index: Int) {
        report(index)
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.25, dampingFraction: 0.85)
        withAnimation(animation) {
            position = Double(index)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if dragOrigin == nil, position == Double(index) {
                position = nil
                lastIndex = nil
            }
        }
    }

    /// Exponential deceleration at ~120 Hz; every detent crossed fires a haptic and a selection.
    private func fling(from start: Double, velocity: Double) {
        flingTask?.cancel()
        flingTask = Task { @MainActor in
            var current = start
            var speed = velocity
            let frame: Double = 1.0 / 120.0
            while !Task.isCancelled, abs(speed) > 1.5 {
                try? await Task.sleep(nanoseconds: 8_333_333)
                current += speed * frame
                speed *= exp(-frame * 5)
                if current <= 0 || current >= Double(maxIndex) {
                    current = min(max(current, 0), Double(maxIndex))
                    position = current
                    report(Int(current.rounded()))
                    break
                }
                position = current
                report(Int(current.rounded()))
            }
            guard !Task.isCancelled else { return }
            settle(at: Int(min(max(current, 0), Double(maxIndex)).rounded()))
        }
    }
}

/// A small downward-pointing triangle above the dial's index line.
private struct DialIndexMarker: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(color))
        }
    }
}

/// All ticks and labels, drawn once. `Equatable` so turning the dial only moves it.
struct DialStrip: View, Equatable {
    let stops: [DialStop]
    let spacing: CGFloat
    let text: Color
    let secondary: Color
    let font: Font

    static func == (lhs: DialStrip, rhs: DialStrip) -> Bool {
        lhs.stops == rhs.stops && lhs.spacing == rhs.spacing && lhs.text == rhs.text && lhs.secondary == rhs.secondary
    }

    var body: some View {
        GeometryReader { geometry in
            let inset = geometry.size.width - CGFloat(max(stops.count - 1, 0)) * spacing
            let leading = inset / 2
            Canvas { context, size in
                for (index, stop) in stops.enumerated() {
                    let x = leading + CGFloat(index) * spacing
                    let tickTop: CGFloat = 6
                    let tickHeight: CGFloat = stop.isMajor ? 14 : 7
                    let rect = CGRect(x: x - 0.5, y: tickTop, width: 1, height: tickHeight)
                    context.fill(Path(rect), with: .color(stop.isMajor ? text : secondary.opacity(0.6)))
                    if let label = stop.label {
                        let resolved = context.resolve(Text(label).font(font).foregroundColor(text))
                        context.draw(resolved, at: CGPoint(x: x, y: tickTop + 14 + 5), anchor: .top)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The Edition's semicircular arc dial face (Slice 3 §4). Same stops and detents; only the drawing
/// differs: ticks sit on an arc and rotate past a fixed index at the top.
struct RotaryDialFace: View {
    let stops: [DialStop]
    let position: Double
    let spacingDegrees: Double
    let theme: CameraTheme

    var body: some View {
        Canvas { context, size in
            let radius = min(size.width * 0.9, size.height * 2.2)
            let center = CGPoint(x: size.width / 2, y: radius + 10)
            for (index, stop) in stops.enumerated() {
                let degrees = (Double(index) - position) * spacingDegrees
                guard abs(degrees) < 80 else { continue }
                let angle = (degrees - 90) * .pi / 180
                let outer = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                let length: CGFloat = stop.isMajor ? 12 : 6
                let inner = CGPoint(x: center.x + cos(angle) * (radius - length), y: center.y + sin(angle) * (radius - length))
                var tick = Path()
                tick.move(to: outer)
                tick.addLine(to: inner)
                let fade = 1 - abs(degrees) / 80
                context.stroke(tick, with: .color(theme.text.opacity(stop.isMajor ? fade : fade * 0.5)), lineWidth: 1)
                if let label = stop.label {
                    let labelPoint = CGPoint(x: center.x + cos(angle) * (radius - 26), y: center.y + sin(angle) * (radius - 26))
                    let resolved = context.resolve(Text(label).font(theme.labelFont).foregroundColor(theme.text.opacity(fade)))
                    context.draw(resolved, at: labelPoint, anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
