import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// UIKit host for the camera image: the preview layer, the Metal overlay (peaking + zebras), the
/// loupe and the blurred snapshot shown during lens switches. All of them use the same
/// `ViewfinderGeometry`.
final class PreviewView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
    }

    let overlayView: MetalOverlayView
    let loupeView: MetalOverlayView
    private let snapshotView = UIImageView()

    /// Tap location in view points and in capture-device coordinates (0…1).
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onLoupeTap: (() -> Void)?
    var onGeometryChange: ((ViewfinderGeometry) -> Void)?
    var onShutter: (() -> Void)?
    private(set) var geometry = ViewfinderGeometry.zero

    /// Loupe panel size relative to the video width.
    private let loupeWidthFraction: CGFloat = 0.42
    private let loupeInset: CGFloat = 10

    init(metalDevice: MTLDevice?) {
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

        addSubview(overlayView)
        addSubview(snapshotView)
        addSubview(loupeView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        let loupeTap = UITapGestureRecognizer(target: self, action: #selector(handleLoupeTap))
        loupeView.addGestureRecognizer(loupeTap)

        // Hardware Camera Control (iPhone 16 / 17 / 18 side button) support
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended {
                    DispatchQueue.main.async {
                        self?.onShutter?()
                    }
                }
            }
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

/// SwiftUI wrapper. The controller receives the view once it exists and wires it to the engine.
struct CameraPreviewView: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView(metalDevice: controller.metalDevice)
        view.onShutter = { [weak controller] in
            controller?.shutterPressed()
        }
        controller.attachPreview(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
