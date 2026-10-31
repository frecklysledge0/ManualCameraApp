import CoreGraphics
import Foundation

/// One description of where the camera image sits on screen. The preview, the Metal overlays,
/// the snapshot used during lens switches and the tap mapping all use the same rect, so they
/// can never drift apart.
struct ViewfinderGeometry: Equatable, Sendable {
    /// Bounds of the preview view.
    var bounds: CGRect
    /// The rect inside `bounds` that shows the image (`.resizeAspect`).
    var videoRect: CGRect

    static let zero = ViewfinderGeometry(bounds: .zero, videoRect: .zero)

    /// Aspect-fit rect of content with `aspectRatio` (width / height) inside `bounds`.
    static func aspectFit(aspectRatio: CGFloat, in bounds: CGRect) -> CGRect {
        guard aspectRatio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let boundsRatio = bounds.width / bounds.height
        var size = bounds.size
        if aspectRatio > boundsRatio {
            size.height = bounds.width / aspectRatio
        } else {
            size.width = bounds.height * aspectRatio
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Normalised (0…1) position of a point within the video rect, or nil when outside it.
    func normalizedPoint(for point: CGPoint) -> CGPoint? {
        guard videoRect.width > 0, videoRect.height > 0, videoRect.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - videoRect.minX) / videoRect.width,
            y: (point.y - videoRect.minY) / videoRect.height
        )
    }

    /// Clamps a point into the video rect so tap indicators never sit outside the image.
    func clampedToVideo(_ point: CGPoint) -> CGPoint {
        guard videoRect.width > 0, videoRect.height > 0 else { return point }
        return CGPoint(
            x: min(max(point.x, videoRect.minX), videoRect.maxX),
            y: min(max(point.y, videoRect.minY), videoRect.maxY)
        )
    }
}

/// Free-space policy (§11): warn below 500 MB, disable RAW below 150 MB.
enum StoragePolicy {
    enum Level: Equatable, Sendable {
        case ok
        case low
        case critical
    }

    static let lowThresholdBytes: Int64 = 500 * 1_000_000
    static let criticalThresholdBytes: Int64 = 150 * 1_000_000

    static func level(forAvailableBytes bytes: Int64?) -> Level {
        guard let bytes else { return .ok }
        if bytes < criticalThresholdBytes { return .critical }
        if bytes < lowThresholdBytes { return .low }
        return .ok
    }
}
