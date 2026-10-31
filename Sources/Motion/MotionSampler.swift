import CoreMotion
import Foundation

struct MotionReading: Equatable, Sendable {
    /// Rotation in the screen plane, degrees, positive when the phone is turned clockwise.
    var rollDegrees: Double
    /// Forward/back tilt, degrees, 0 when the phone is vertical.
    var pitchDegrees: Double
}

/// Device-motion sampling on a private queue (F2). Readings are published to the main queue at
/// most 30 times a second, and only when roll or pitch moved by more than 0.1°.
final class MotionSampler: @unchecked Sendable {

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "camera.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private let minimumInterval: TimeInterval = 1.0 / 30.0
    private let minimumChange: Double = 0.1

    // Confined to `queue`.
    private var lastPublished: MotionReading?
    private var lastPublishTime: TimeInterval = 0

    /// Called on the main queue.
    var onReading: ((MotionReading) -> Void)?

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    var isActive: Bool { manager.isDeviceMotionActive }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        queue.addOperation { [weak self] in
            self?.lastPublished = nil
        }
    }

    private func handle(_ motion: CMDeviceMotion) {
        let gravity = motion.gravity
        let reading = MotionReading(
            rollDegrees: RotationMath.screenRollDegrees(gravityX: gravity.x, gravityY: gravity.y),
            pitchDegrees: RotationMath.pitchDegrees(gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z)
        )
        let now = motion.timestamp
        guard now - lastPublishTime >= minimumInterval else { return }
        if let lastPublished,
           abs(RotationMath.continuousAngle(previous: lastPublished.rollDegrees, target: reading.rollDegrees) - lastPublished.rollDegrees) <= minimumChange,
           abs(reading.pitchDegrees - lastPublished.pitchDegrees) <= minimumChange {
            return
        }
        lastPublished = reading
        lastPublishTime = now
        let callback = onReading
        DispatchQueue.main.async {
            callback?(reading)
        }
    }
}
