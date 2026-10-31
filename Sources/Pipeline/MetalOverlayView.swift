import Metal
import QuartzCore
import UIKit

/// A transparent `UIView` backed by a `CAMetalLayer`. `FramePipeline` renders focus peaking
/// straight into its drawables on the video queue, so drawing it costs the main thread nothing.
final class MetalOverlayView: UIView {

    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer {
        // layerClass guarantees the type.
        layer as! CAMetalLayer // swiftlint:disable:this force_cast
    }

    /// Longest drawable edge in pixels; the overlay does not need more than the screen.
    private let maxDrawableDimension: CGFloat = 2200

    init(device: MTLDevice?) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        let metal = metalLayer
        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = false
        metal.isOpaque = false
        metal.backgroundColor = UIColor.clear.cgColor
        metal.presentsWithTransaction = false
        metal.maximumDrawableCount = 3
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        var size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let longest = max(size.width, size.height)
        if longest > maxDrawableDimension {
            let factor = maxDrawableDimension / longest
            size = CGSize(width: size.width * factor, height: size.height * factor)
        }
        guard size.width >= 1, size.height >= 1 else { return }
        metalLayer.contentsScale = scale
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        if metalLayer.drawableSize != rounded {
            metalLayer.drawableSize = rounded
        }
    }
}
