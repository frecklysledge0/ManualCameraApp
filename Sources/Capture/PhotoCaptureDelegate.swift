import AVFoundation

extension AVCapturePhoto: CapturedPhotoPayload {}

/// The `AVCapturePhotoCaptureDelegate` for one shot. It forwards every callback to its
/// `PhotoCaptureProcessor`, which holds the logic (and is unit-tested without AVFoundation).
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    let processor: PhotoCaptureProcessor
    /// Called at `willBeginCapture` (Slice 3 plays the leaf-shutter sound here).
    var onWillBeginCapture: (() -> Void)?

    init(processor: PhotoCaptureProcessor) {
        self.processor = processor
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onWillBeginCapture?()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        processor.handleWillCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        processor.handleProcessedPhoto(photo, error: error)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        processor.handleCaptureFinished(error: error)
    }
}
