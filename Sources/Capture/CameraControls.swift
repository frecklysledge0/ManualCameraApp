import AVFoundation

/// Camera Control integration (iPhone 16 and later, iOS 18+), the same mechanism Blackmagic
/// Camera uses: a light press opens an overlay with the app's controls and sliding the finger on
/// Camera Control changes the selected one; a light double-press switches control.
///
/// iOS gives apps no separate "light press" event. The session's controls delegate reports when
/// the overlay opens, so the app treats that moment as the half-press and focuses. A full click
/// arrives separately through `AVCaptureEventInteraction` (see `PreviewView`).
@available(iOS 18.0, *)
@MainActor
final class CameraControlSet {

    /// What the controls were built from; a change rebuilds them.
    struct Content: Equatable {
        var shutterStops: [Double]
        var isoStops: [Float]
        /// Ascending ƒ-numbers (empty on fixed-aperture lenses).
        var apertureStops: [Float]
        var evStops: [Float]
        var lensTitles: [String]
    }

    struct Actions {
        var shutter: @MainActor @Sendable (Int) -> Void
        var iso: @MainActor @Sendable (Int) -> Void
        var aperture: @MainActor @Sendable (Int) -> Void
        var exposure: @MainActor @Sendable (Float) -> Void
        var focus: @MainActor @Sendable (Float) -> Void
        var lens: @MainActor @Sendable (Int) -> Void
    }

    let content: Content
    private let shutter: AVCaptureIndexPicker?
    private let iso: AVCaptureIndexPicker?
    private let aperture: AVCaptureIndexPicker?
    private let exposure: AVCaptureSlider?
    private let focus: AVCaptureSlider
    private let lens: AVCaptureIndexPicker?

    /// In the order the overlay lists them.
    var controls: [AVCaptureControl] {
        var list: [AVCaptureControl] = []
        if let shutter { list.append(shutter) }
        if let iso { list.append(iso) }
        if let aperture { list.append(aperture) }
        if let exposure { list.append(exposure) }
        list.append(focus)
        if let lens { list.append(lens) }
        return list
    }

    /// The actions run on the main queue.
    init(content: Content, actions: Actions) {
        self.content = content

        shutter = Self.picker("Shutter", symbol: "timer", titles: content.shutterStops.map { ExposureMath.formatShutter($0) }, action: actions.shutter)
        iso = Self.picker("ISO", symbol: "sun.max", titles: content.isoStops.map { ExposureMath.formatISO($0) }, action: actions.iso)
        aperture = Self.picker("Aperture", symbol: "camera.aperture", titles: content.apertureStops.map { ExposureMath.formatAperture($0) }, action: actions.aperture)
        lens = Self.picker("Lens", symbol: "camera.viewfinder", titles: content.lensTitles, action: actions.lens)

        if content.evStops.count > 1 {
            let slider = AVCaptureSlider("Exposure", symbolName: "plusminus.circle", values: content.evStops)
            slider.localizedValueFormat = "%+.1f EV"
            slider.prominentValues = content.evStops.filter { abs($0 - $0.rounded()) < 0.01 }
            let onChange = actions.exposure
            slider.setActionQueue(.main) { value in
                MainActor.assumeIsolated { onChange(value) }
            }
            exposure = slider
        } else {
            exposure = nil
        }

        let focusSlider = AVCaptureSlider("Focus", symbolName: "scope", in: 0...1)
        let onFocus = actions.focus
        focusSlider.setActionQueue(.main) { value in
            MainActor.assumeIsolated { onFocus(value) }
        }
        focus = focusSlider
    }

    private static func picker(_ title: String, symbol: String, titles: [String], action: @escaping @MainActor @Sendable (Int) -> Void) -> AVCaptureIndexPicker? {
        guard titles.count > 1 else { return nil }
        let picker = AVCaptureIndexPicker(title, symbolName: symbol, localizedIndexTitles: titles)
        picker.setActionQueue(.main) { index in
            MainActor.assumeIsolated { action(index) }
        }
        return picker
    }

    /// Shows the current settings when the overlay opens.
    func sync(shutter seconds: Double, iso value: Float, aperture fNumber: Float, bias: Float, lensPosition: Float, lensIndex: Int?) {
        if let shutter, !content.shutterStops.isEmpty {
            shutter.selectedIndex = ExposureMath.nearestIndex(of: seconds, in: content.shutterStops)
        }
        if let iso, !content.isoStops.isEmpty {
            iso.selectedIndex = ExposureMath.nearestIndex(of: value, in: content.isoStops)
        }
        if let aperture, !content.apertureStops.isEmpty {
            aperture.selectedIndex = ExposureMath.nearestIndex(of: fNumber, in: content.apertureStops)
        }
        if let exposure, !content.evStops.isEmpty {
            exposure.value = content.evStops[ExposureMath.nearestLinearIndex(of: bias, in: content.evStops)]
        }
        focus.value = ExposureMath.clamp(lensPosition, 0, 1)
        if let lens, let lensIndex, content.lensTitles.indices.contains(lensIndex) {
            lens.selectedIndex = lensIndex
        }
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
