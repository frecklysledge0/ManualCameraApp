import AVFoundation

/// Camera Control integration (iPhone 16 and later, iOS 18+).
///
/// iOS gives apps no direct "light press" event. A light press opens the Camera Control overlay
/// with the app's controls, and the session's controls delegate reports that, so the app treats
/// "controls became active" as the half-press and focuses then. A full click arrives separately
/// through `AVCaptureEventInteraction` (see `PreviewView`).
@available(iOS 18.0, *)
@MainActor
final class CameraControlSet {

    /// Ascending ƒ-numbers (empty on fixed-aperture lenses).
    let apertureStops: [Float]
    let evStops: [Float]
    let aperture: AVCaptureSlider?
    let exposure: AVCaptureSlider?
    let focus: AVCaptureSlider

    var controls: [AVCaptureControl] {
        var list: [AVCaptureControl] = []
        if let aperture { list.append(aperture) }
        if let exposure { list.append(exposure) }
        list.append(focus)
        return list
    }

    /// The actions run on the main queue.
    init(
        apertureStops: [Float],
        evStops: [Float],
        onAperture: @escaping @MainActor @Sendable (Float) -> Void,
        onExposure: @escaping @MainActor @Sendable (Float) -> Void,
        onFocus: @escaping @MainActor @Sendable (Float) -> Void
    ) {
        self.apertureStops = apertureStops
        self.evStops = evStops

        if apertureStops.count > 1 {
            let slider = AVCaptureSlider("Aperture", symbolName: "camera.aperture", values: apertureStops)
            slider.localizedValueFormat = "ƒ/%.1f"
            slider.prominentValues = apertureStops.filter { ExposureMath.isFullStop(aperture: $0) }
            slider.setActionQueue(.main) { value in
                MainActor.assumeIsolated { onAperture(value) }
            }
            aperture = slider
        } else {
            aperture = nil
        }

        if evStops.count > 1 {
            let slider = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", values: evStops)
            slider.localizedValueFormat = "%+.1f EV"
            slider.prominentValues = evStops.filter { abs($0 - $0.rounded()) < 0.01 }
            slider.setActionQueue(.main) { value in
                MainActor.assumeIsolated { onExposure(value) }
            }
            exposure = slider
        } else {
            exposure = nil
        }

        let focusSlider = AVCaptureSlider("Focus", symbolName: "scope", in: 0...1)
        focusSlider.setActionQueue(.main) { value in
            MainActor.assumeIsolated { onFocus(value) }
        }
        focus = focusSlider
    }

    /// Shows the current settings when the overlay opens.
    func sync(aperture fNumber: Float, bias: Float, lensPosition: Float) {
        if let aperture, !apertureStops.isEmpty {
            aperture.value = apertureStops[ExposureMath.nearestIndex(of: fNumber, in: apertureStops)]
        }
        if let exposure, !evStops.isEmpty {
            exposure.value = evStops[ExposureMath.nearestLinearIndex(of: bias, in: evStops)]
        }
        focus.value = ExposureMath.clamp(lensPosition, 0, 1)
    }
}

/// Reports when the Camera Control overlay opens (a light press) and closes.
@available(iOS 18.0, *)
final class CameraControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {

    /// Called on the queue given to `setControlsDelegate` (main).
    let onActiveChange: (Bool) -> Void

    init(onActiveChange: @escaping (Bool) -> Void) {
        self.onActiveChange = onActiveChange
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        onActiveChange(true)
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {}

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {}

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        onActiveChange(false)
    }
}
