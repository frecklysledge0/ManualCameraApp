import SwiftUI

/// RGB or luma histogram drawn with `Canvas`, with clip markers (Slice 2 §9). Only this view reads
/// `telemetry.histogram`.
struct HistogramView: View {
    let telemetry: LiveTelemetry
    let mode: HistogramMode
    var showsFrame = true
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let sample = telemetry.histogram
        let clipColor = theme.clip
        let lineColor = theme.text
        let minimal = theme.telemetry == .minimal
        Canvas { context, size in
            let frame = CGRect(origin: .zero, size: size)
            if showsFrame && !minimal {
                context.fill(Path(frame), with: .color(.black.opacity(0.35)))
            }
            guard !sample.isEmpty else { return }
            switch mode {
            case .rgb where !minimal:
                context.blendMode = .screen
                context.fill(Self.path(for: sample.red, in: size), with: .color(.red.opacity(0.65)))
                context.fill(Self.path(for: sample.green, in: size), with: .color(.green.opacity(0.65)))
                context.fill(Self.path(for: sample.blue, in: size), with: .color(.blue.opacity(0.65)))
                context.blendMode = .normal
            default:
                if minimal {
                    context.stroke(Self.path(for: sample.luma, in: size, closed: false), with: .color(lineColor.opacity(0.8)), lineWidth: 1)
                } else {
                    context.fill(Self.path(for: sample.luma, in: size), with: .color(lineColor.opacity(0.75)))
                }
            }
            // Clip markers: more than 0.5% of pixels in the first or last bin.
            if sample.clipsShadows {
                context.fill(Path(CGRect(x: 0, y: 0, width: 2, height: size.height)), with: .color(clipColor))
            }
            if sample.clipsHighlights {
                context.fill(Path(CGRect(x: size.width - 2, y: 0, width: 2, height: size.height)), with: .color(clipColor))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(sample.clipsHighlights ? "Highlights clipping" : (sample.clipsShadows ? "Shadows clipping" : "No clipping"))
    }

    static func path(for bins: [Float], in size: CGSize, closed: Bool = true) -> Path {
        Path { path in
            guard !bins.isEmpty else { return }
            let step = size.width / CGFloat(max(bins.count - 1, 1))
            if closed {
                path.move(to: CGPoint(x: 0, y: size.height))
            }
            for (index, value) in bins.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: size.height - CGFloat(value) * size.height * 0.95)
                if index == 0 && !closed {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            if closed {
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
            }
        }
    }
}
