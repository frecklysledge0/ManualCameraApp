import AVFoundation
import QuartzCore

/// Wraps `AVCaptureDevice.RotationCoordinator` for the active device (§9).
///
/// - The **preview** angle is pushed to the preview layer's connection (the UI is locked to
///   portrait, so in practice it stays at the portrait angle).
/// - The **capture** angle is read at the moment of capture, so landscape and upside-down shots are
///   saved upright.
/// - The video data output is left unrotated; the Metal kernels map overlay pixels into the sensor
///   buffer with `RotationMath.bufferPoint`, which avoids rotating every frame on the CPU.
final class RotationController: @unchecked Sendable {

    private let lock = NSLock()
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var latestCaptureAngle: CGFloat = 90
    private var latestPreviewAngle: CGFloat = 90

    /// Called (on any thread) when the preview angle changes.
    var onPreviewAngleChange: ((CGFloat) -> Void)?

    var captureAngle: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        if let coordinator {
            return coordinator.videoRotationAngleForHorizonLevelCapture
        }
        return latestCaptureAngle
    }

    var previewAngle: CGFloat {
        lock.lock()
        defer { lock.unlock() }
        return latestPreviewAngle
    }

    /// Re-binds to a new device. Must be called after the device's input was added to the session.
    func bind(device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer?) {
        let newCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)

        lock.lock()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        coordinator = newCoordinator
        latestPreviewAngle = newCoordinator.videoRotationAngleForHorizonLevelPreview
        latestCaptureAngle = newCoordinator.videoRotationAngleForHorizonLevelCapture
        lock.unlock()

        let previewObservation = newCoordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            self?.updatePreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)
        }
        let captureObservation = newCoordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coordinator, _ in
            self?.updateCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        }

        lock.lock()
        observations = [previewObservation, captureObservation]
        let angle = latestPreviewAngle
        lock.unlock()
        onPreviewAngleChange?(angle)
    }

    func unbind() {
        lock.lock()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        coordinator = nil
        lock.unlock()
    }

    private func updatePreviewAngle(_ angle: CGFloat) {
        lock.lock()
        let changed = angle != latestPreviewAngle
        latestPreviewAngle = angle
        lock.unlock()
        if changed { onPreviewAngleChange?(angle) }
    }

    private func updateCaptureAngle(_ angle: CGFloat) {
        lock.lock()
        latestCaptureAngle = angle
        lock.unlock()
    }
}
