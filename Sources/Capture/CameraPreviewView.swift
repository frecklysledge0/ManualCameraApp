import AVFoundation
import SwiftUI
import UIKit

/// UIKit host for the camera image: the preview layer, the Metal peaking overlay and the blurred
/// snapshot shown during lens switches. All three use the same `ViewfinderGeometry`.
final class PreviewView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
    }

    let overlayView: MetalOverlayView
    private let snapshotView = UIImageView()

    /// Tap location in view points and in capture-device coordinates (0…1).
    var onTap: ((CGPoint, CGPoint) -> Void)?
    var onGeometryChange: ((ViewfinderGeometry) -> Void)?
    private(set) var geometry = ViewfinderGeometry.zero

    init(metalDevice: MTLDevice?) {
        overlayView = MetalOverlayView(device: metalDevice)
        super.init(frame: .zero)
        backgroundColor = .black
        videoPreviewLayer.videoGravity = .resizeAspect

        snapshotView.contentMode = .scaleToFill
        snapshotView.alpha = 0
        snapshotView.isUserInteractionEnabled = false
        addSubview(overlayView)
        addSubview(snapshotView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
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
        if newGeometry != geometry {
            geometry = newGeometry
            onGeometryChange?(newGeometry)
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard geometry.videoRect.contains(point) else { return }
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        onTap?(point, devicePoint)
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
        controller.attachPreview(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
