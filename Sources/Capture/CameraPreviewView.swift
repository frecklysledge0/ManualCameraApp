import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// UIKit host for the camera image: the preview layer, the Edition's look layer, the Metal overlay
/// (peaking + zebras), the loupe and the blurred snapshot shown during lens switches. All of them
/// use the same `ViewfinderGeometry`.
final class PreviewView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
    }

    /// The Edition's live look (Slice 3 §7): an opaque layer above the preview layer that shows each
    /// frame through the same LUT as the developed photo. Hidden in the Pro theme.
    let lookView: MetalOverlayView
    let overlayView: MetalOverlayView
    let loupeView: MetalOverlayView
    private let snapshotView = UIImageView()
    private var tapRecognizer: UITapGestureRecognizer?

    /// Tap location in view points and in capture-device coordinates (0…1).
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onLoupeTap: (() -> Void)?
    /// Long-press on the viewfinder: return the focus point to the centre.
    var onLongPress: (() -> Void)?
    var onGeometryChange: ((ViewfinderGeometry) -> Void)?
    /// Camera Control and the volume buttons (Sony-style: press = focus, release = shoot).
    var onHardwareShutter: ((HardwareShutterPhase) -> Void)?
    private(set) var geometry = ViewfinderGeometry.zero

    /// Loupe panel size relative to the video width.
    private let loupeWidthFraction: CGFloat = 0.42
    private let loupeInset: CGFloat = 10

    init(metalDevice: MTLDevice?) {
        lookView = MetalOverlayView(device: metalDevice, maxDrawableDimension: 1600)
        overlayView = MetalOverlayView(device: metalDevice, maxDrawableDimension: 1100)
        loupeView = MetalOverlayView(device: metalDevice, maxDrawableDimension: 900)
        super.init(frame: .zero)
        backgroundColor = .black
        videoPreviewLayer.videoGravity = .resizeAspect

        snapshotView.contentMode = .scaleToFill
        snapshotView.alpha = 0
        snapshotView.isUserInteractionEnabled = false

        loupeView.alpha = 0
        loupeView.isUserInteractionEnabled = true
        loupeView.layer.cornerRadius = 6
        loupeView.layer.masksToBounds = true
        loupeView.layer.borderWidth = 1
        loupeView.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        loupeView.metalLayer.isOpaque = true
        loupeView.accessibilityLabel = "Focus loupe"
        loupeView.accessibilityTraits = .button

        lookView.alpha = 0
        lookView.isHidden = true
        lookView.backgroundColor = .black
        lookView.metalLayer.isOpaque = true

        addSubview(lookView)
        addSubview(overlayView)
        addSubview(snapshotView)
        addSubview(loupeView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        tapRecognizer = tap
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        addGestureRecognizer(longPress)
        let loupeTap = UITapGestureRecognizer(target: self, action: #selector(handleLoupeTap))
        loupeView.addGestureRecognizer(loupeTap)

        // Hardware shutter: Camera Control (iPhone 16 and later) and the volume buttons. Like a
        // camera's shutter button, pressing focuses at the focus frame and releasing takes the
        // photo. Events arrive on the main thread.
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak self] event in
                let phase: HardwareShutterPhase
                switch event.phase {
                case .began: phase = .pressed
                case .ended: phase = .released
                case .cancelled: phase = .cancelled
                @unknown default: return
                }
                MainActor.assumeIsolated { self?.onHardwareShutter?(phase) }
            }
            interaction.isEnabled = true
            addInteraction(interaction)
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshGeometry()
    }

    /// Recomputes where the video sits. Call after a lens or format change.
    func refreshGeometry() {
        var videoRect = videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        if videoRect.isNull || videoRect.isInfinite || videoRect.width < 1 || videoRect.height < 1 {
            videoRect = ViewfinderGeometry.aspectFit(aspectRatio: 3.0 / 4.0, in: bounds)
        }
        let newGeometry = ViewfinderGeometry(bounds: bounds, videoRect: videoRect.integral)
        if overlayView.frame != newGeometry.videoRect {
            overlayView.frame = newGeometry.videoRect
        }
        if lookView.frame != newGeometry.videoRect {
            lookView.frame = newGeometry.videoRect
        }
        snapshotView.frame = newGeometry.videoRect
        let side = (newGeometry.videoRect.width * loupeWidthFraction).rounded()
        loupeView.frame = CGRect(
            x: newGeometry.videoRect.maxX - side - loupeInset,
            y: newGeometry.videoRect.minY + loupeInset,
            width: side,
            height: side
        )
        if newGeometry != geometry {
            geometry = newGeometry
            onGeometryChange?(newGeometry)
        }
    }

    /// Display-uv size of the region the loupe shows at `zoom` × magnification.
    func loupeWindow(zoom: Int) -> CGSize {
        let video = geometry.videoRect
        guard video.width > 0, video.height > 0, zoom > 0 else { return CGSize(width: 0.1, height: 0.1) }
        let factor = CGFloat(zoom)
        return CGSize(
            width: loupeView.bounds.width / (factor * video.width),
            height: loupeView.bounds.height / (factor * video.height)
        )
    }

    func setLoupeVisible(_ visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        guard loupeView.alpha != target else { return }
        UIView.animate(withDuration: visible ? 0.12 : 0.2, delay: 0, options: [.beginFromCurrentState]) {
            self.loupeView.alpha = target
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard geometry.videoRect.contains(point) else { return }
        // Taps on the visible loupe belong to the loupe.
        if loupeView.alpha > 0.01, loupeView.frame.contains(point) { return }
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        onTap?(point, devicePoint)
    }

    @objc private func handleLoupeTap() {
        onLoupeTap?()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        guard geometry.videoRect.contains(point) else { return }
        if loupeView.alpha > 0.01, loupeView.frame.contains(point) { return }
        // Cancel the tap that would otherwise fire when the finger lifts.
        tapRecognizer?.isEnabled = false
        tapRecognizer?.isEnabled = true
        onLongPress?()
    }

    /// Capture-device point (0…1, sensor orientation) for a point in video uv, for focusing at
    /// the focus frame without a tap.
    func devicePoint(forVideoUV uv: CGPoint) -> CGPoint {
        let video = geometry.videoRect
        guard video.width > 0, video.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let point = CGPoint(x: video.minX + uv.x * video.width, y: video.minY + uv.y * video.height)
        return videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
    }

    // MARK: - Edition look layer

    /// Fades the look layer in or out (0.35 s, Slice 3 §4).
    func setLookVisible(_ visible: Bool, animated: Bool = true) {
        let target: CGFloat = visible ? 1 : 0
        if visible { lookView.isHidden = false }
        let apply = { self.lookView.alpha = target }
        let finish: (Bool) -> Void = { _ in
            if !visible, self.lookView.alpha == 0 { self.lookView.isHidden = true }
        }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: apply, completion: finish)
        } else {
            apply()
            finish(true)
        }
    }

    // MARK: - Lens-switch snapshot

    func showSnapshot(_ image: CGImage?) {
        guard let image else { return }
        snapshotView.layer.removeAllAnimations()
        snapshotView.image = UIImage(cgImage: image)
        snapshotView.alpha = 1
    }

    func hideSnapshot(duration: TimeInterval = 0.18) {
        guard snapshotView.alpha > 0 else { return }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
            self.snapshotView.alpha = 0
        } completion: { finished in
            if finished { self.snapshotView.image = nil }
        }
    }
}

/// A hardware shutter event.
enum HardwareShutterPhase: Sendable {
    /// Pressed down: focus (the half-press of a camera's shutter button).
    case pressed
    /// Released: take the photo.
    case released
    /// The system took the press (for example, it opened another app).
    case cancelled
}

/// SwiftUI wrapper. The controller receives the view once it exists and wires it to the engine.
struct CameraPreviewView: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(metalDevice: controller.metalDevice)
        view.onHardwareShutter = { [weak controller] phase in
            controller?.hardwareShutter(phase)
        }
        controller.attachPreview(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
