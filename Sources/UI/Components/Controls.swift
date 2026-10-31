import SwiftUI

/// A small badge such as `RAW`, `P`, `1:1` (accent outline in the Pro theme, inverted in the Edition).
struct BadgeView: View {
    let text: String
    var isActive = true
    @Environment(\.cameraTheme) var theme

    init(_ text: String, isActive: Bool = true) {
        self.text = text
        self.isActive = isActive
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.badgeCornerRadius)
        Text(text)
            .font(theme.labelFont.weight(.bold))
            .tracking(theme.labelTracking)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundColor(foreground)
            .background(background, in: shape)
            .overlay(shape.stroke(stroke, lineWidth: 1))
    }

    private var foreground: Color {
        switch theme.badge {
        case .accentOutline: return isActive ? theme.accent : theme.secondaryText
        case .inverted: return isActive ? theme.background : theme.secondaryText
        }
    }

    private var background: Color {
        switch theme.badge {
        case .accentOutline: return .clear
        case .inverted: return isActive ? theme.text : .clear
        }
    }

    private var stroke: Color {
        switch theme.badge {
        case .accentOutline: return isActive ? theme.accent : theme.hairline
        case .inverted: return isActive ? theme.text : theme.hairline
        }
    }
}

/// The shutter button. It dims while the photo output isn't ready (Slice 1 §6.3).
struct ShutterButton: View {
    let status: CaptureStatus
    let action: () -> Void
    @Environment(\.cameraTheme) var theme
    @GestureState var isPressed = false

    init(status: CaptureStatus, action: @escaping () -> Void) {
        self.status = status
        self.action = action
    }

    var body: some View {
        let ready = status.canCapture
        ZStack {
            switch theme.shutter {
            case .ring:
                Circle()
                    .stroke(theme.text, lineWidth: 3)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(theme.text)
                    .frame(width: 64, height: 64)
                    .scaleEffect(isPressed ? 0.9 : 1)
            case .flatDisc:
                Circle()
                    .stroke(theme.text.opacity(0.6), lineWidth: 1)
                    .frame(width: 80, height: 80)
                Circle()
                    .fill(theme.text)
                    .frame(width: 70, height: 70)
                    .offset(y: isPressed ? 2 : 0)
                    .scaleEffect(isPressed ? 0.96 : 1)
            }
        }
        .opacity(ready ? 1 : 0.45)
        .animation(theme.pressAnimation, value: isPressed)
        .animation(.easeOut(duration: 0.12), value: ready)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
                .onEnded { value in
                    if abs(value.translation.width) < 60, abs(value.translation.height) < 60 {
                        action()
                    }
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Take photo")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

struct GalleryButton: View {
    let controller: CameraController
    @Environment(\.cameraTheme) var theme

    var body: some View {
        Button {
            controller.openGallery()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(theme.surfaceRaised)
                if let thumbnail = controller.status.lastThumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundColor(theme.secondaryText)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.hairline, lineWidth: 1))
            .rotatesWithDevice(controller.telemetry)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Photos")
    }
}

/// Lens buttons with computed labels, plus the front-camera toggle.
struct LensSelector: View {
    let controller: CameraController
    @Environment(\.cameraTheme) var theme

    var body: some View {
        let settings = controller.settings
        VStack(spacing: 8) {
            if !settings.isFrontCamera {
                HStack(spacing: 2) {
                    ForEach(settings.backLenses) { lens in
                        let selected = lens == settings.lens
                        Button {
                            controller.switchLens(lens)
                        } label: {
                            Text(selected ? lens.buttonText + "×" : lens.buttonText)
                                .font(theme.telemetryFont)
                                .monospacedDigit()
                                .foregroundColor(selected ? theme.emphasis : theme.secondaryText)
                                .frame(width: 34, height: 30)
                                .background(selected ? theme.surfaceRaised : Color.clear, in: Capsule())
                                .rotatesWithDevice(controller.telemetry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(lens.buttonText) times lens")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(2)
                .background(theme.surface, in: Capsule())
            }
            Button {
                controller.toggleFrontCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 17))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 34, height: 28)
                    .rotatesWithDevice(controller.telemetry)
            }
            .buttonStyle(.plain)
            .disabled(settings.lenses.first(where: { $0.isFront }) == nil)
            .accessibilityLabel("Switch camera")
        }
    }
}
