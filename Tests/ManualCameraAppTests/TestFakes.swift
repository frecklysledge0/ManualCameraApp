import CoreGraphics
import Foundation
@testable import ManualCameraApp

struct FakeError: Error, Equatable {
    var code = 1
}

/// Manual clock: scheduled work runs only when `runDue` or `advance` is called.
final class FakeScheduler: CommandScheduler {
    var now: TimeInterval = 0
    private(set) var scheduled: [(time: TimeInterval, work: () -> Void)] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        scheduled.append((now + max(0, delay), work))
    }

    func runDue() {
        while let index = scheduled.firstIndex(where: { $0.time <= now + 1e-12 }) {
            let item = scheduled.remove(at: index)
            item.work()
        }
    }

    func advance(by interval: TimeInterval) {
        now += interval
        runDue()
    }
}

/// Records every call the engine makes to the hardware.
final class FakeCameraDevice: CameraDevice {
    var identifier: String
    var limits: DeviceLimits

    var currentISO: Float = 200
    var currentDuration: Double = 1.0 / 100
    var currentBias: Float = 0
    var currentLensPosition: Float = 0.42
    var currentAperture: Float = 1.48
    var exposureTargetOffset: Float = 0
    var currentWhiteBalance: (temperature: Float, tint: Float) = (5200, 0)

    var failingLocks = 0
    private(set) var lockCalls = 0
    private(set) var unlockCalls = 0
    private(set) var customExposures: [(duration: Double, iso: Float)] = []
    private(set) var priorityExposures: [(aperture: Float?, duration: Double?, iso: Float?)] = []
    private(set) var autoExposureBiases: [Float] = []
    private(set) var biasChanges: [Float] = []
    private(set) var exposurePoints: [CGPoint] = []
    private(set) var whiteBalanceLocks: [(temperature: Float, tint: Float)] = []
    private(set) var autoWhiteBalanceCount = 0
    private(set) var focusCommands: [FocusCommand] = []

    init(identifier: String = "fake", limits: DeviceLimits = DeviceLimits()) {
        self.identifier = identifier
        self.limits = limits
    }

    func lockForConfiguration() throws {
        lockCalls += 1
        if failingLocks > 0 {
            failingLocks -= 1
            throw FakeError()
        }
    }

    func unlockForConfiguration() {
        unlockCalls += 1
    }

    func applyContinuousAutoExposure(bias: Float) {
        autoExposureBiases.append(bias)
    }

    func applyExposureBias(_ bias: Float) {
        biasChanges.append(bias)
    }

    func applyCustomExposure(duration: Double, iso: Float) {
        customExposures.append((duration, iso))
    }

    func applyPriorityExposure(aperture: Float?, duration: Double?, iso: Float?) {
        priorityExposures.append((aperture, duration, iso))
    }

    func applyExposurePoint(_ point: CGPoint) {
        exposurePoints.append(point)
    }

    func applyAutoWhiteBalance() {
        autoWhiteBalanceCount += 1
    }

    func applyLockedWhiteBalance(temperature: Float, tint: Float) -> (temperature: Float, tint: Float) {
        whiteBalanceLocks.append((temperature, tint))
        return (temperature, tint)
    }

    func applyFocus(_ command: FocusCommand) {
        focusCommands.append(command)
    }
}

struct FakePhoto: CapturedPhotoPayload {
    var isRawPhoto: Bool
    var data: Data?

    func fileDataRepresentation() -> Data? { data }
}

final class FakeSaver: PhotoLibrarySaving {
    var result: Result<SaveDestination, Error> = .success(.photoLibrary)
    private(set) var savedItems: [CaptureItem] = []

    func save(_ item: CaptureItem, completion: @escaping (Result<SaveDestination, Error>) -> Void) {
        savedItems.append(item)
        completion(result)
    }
}

/// In-memory store that still writes the DNG to a temporary file, like the real one.
final class FakeStore: CaptureFileStoring {
    let directory: URL
    private(set) var removed: [UUID] = []
    private(set) var persisted: [CaptureItem] = []
    var failRawWrites = false

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FakeStore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func writeRaw(_ data: Data, for id: UUID) throws -> URL {
        if failRawWrites { throw FakeError(code: 2) }
        let url = directory.appendingPathComponent("\(id.uuidString).dng")
        try data.write(to: url)
        return url
    }

    func persistPending(_ item: CaptureItem) throws {
        persisted.append(item)
    }

    func remove(_ id: UUID) {
        removed.append(id)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).dng"))
    }

    func pendingItems() -> [CaptureItem] { persisted }

    func removeOrphans() {}

    func exportToDocuments(_ item: CaptureItem) throws -> URL {
        directory.appendingPathComponent("exported")
    }
}
