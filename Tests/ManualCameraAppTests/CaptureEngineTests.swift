import CoreGraphics
import XCTest
@testable import ManualCameraApp

/// The engine's device-command core (`DeviceController`) with a fake camera: coalescing (§6.1),
/// the EV / manual rules (F7) and clamping on a lens switch (§8).
final class CaptureEngineTests: XCTestCase {

    private var scheduler: FakeScheduler!
    private var controller: DeviceController!
    private var device: FakeCameraDevice!
    private var applied: [AppliedDeviceState] = []

    override func setUp() {
        super.setUp()
        scheduler = FakeScheduler()
        controller = DeviceController(scheduler: scheduler, minimumInterval: 1.0 / 60.0)
        controller.onApplied = { [weak self] in self?.applied.append($0) }
        var limits = DeviceLimits()
        limits.minISO = 50
        limits.maxISO = 6400
        limits.minDuration = 1.0 / 40000
        limits.maxDuration = 1.0 / 3
        limits.minBias = -8
        limits.maxBias = 8
        device = FakeCameraDevice(identifier: "wide", limits: limits)
        controller.bind(device)
        applied = []
    }

    // MARK: - Coalescing

    func testHundredCommandsCoalesceIntoOneLock() {
        for index in 0..<100 {
            controller.submit(.exposure(.custom(iso: Float(100 + index), duration: 0.01)))
        }
        XCTAssertEqual(scheduler.scheduled.count, 1, "Only one flush may be scheduled")
        scheduler.runDue()
        XCTAssertEqual(device.lockCalls, 1)
        XCTAssertEqual(device.customExposures.count, 1)
        XCTAssertEqual(device.customExposures.last?.iso, 199, "Latest value wins")
        XCTAssertEqual(device.lockCalls, device.unlockCalls)
    }

    func testSliderDragAt120HzLocksAtMostOncePerFrame() {
        for index in 0..<120 {
            scheduler.now = Double(index) / 120
            controller.submit(.exposure(.custom(iso: 100, duration: 0.01 + Double(index) * 1e-5)))
            scheduler.runDue()
        }
        scheduler.advance(by: 0.1)
        XCTAssertLessThanOrEqual(device.lockCalls, 61)
        XCTAssertGreaterThanOrEqual(device.lockCalls, 50)
        XCTAssertEqual(device.customExposures.last!.duration, 0.01 + 119e-5, accuracy: 1e-12, "The final value is always applied")
    }

    func testFlushWaitsForTheFrameInterval() {
        controller.submit(.exposure(.custom(iso: 100, duration: 0.01)))
        scheduler.runDue()
        XCTAssertEqual(device.lockCalls, 1)

        scheduler.now = 0.001
        controller.submit(.exposure(.custom(iso: 200, duration: 0.01)))
        scheduler.runDue()
        XCTAssertEqual(device.lockCalls, 1, "Second flush must wait for the interval")

        scheduler.advance(by: 0.02)
        XCTAssertEqual(device.lockCalls, 2)
    }

    func testOneLockAppliesAllSlots() {
        controller.submit(.exposure(.auto(bias: 0.3)))
        controller.submit(.whiteBalance(.locked(temperature: 4000, tint: 0)))
        controller.submit(.focus(.locked(lensPosition: 0.7)))
        scheduler.runDue()
        XCTAssertEqual(device.lockCalls, 1)
        XCTAssertEqual(device.autoExposureBiases, [0.3])
        XCTAssertEqual(device.whiteBalanceLocks.count, 1)
        XCTAssertEqual(device.focusCommands, [.locked(lensPosition: 0.7)])
        XCTAssertEqual(applied.count, 1)
    }

    // MARK: - EV and manual rules (F7)

    func testBiasIgnoredWhileManual() {
        controller.submit(.exposure(.custom(iso: 100, duration: 0.01)))
        scheduler.runDue()
        scheduler.advance(by: 0.1)
        controller.submit(.exposure(.bias(1)))
        scheduler.advance(by: 0.1)
        XCTAssertTrue(device.biasChanges.isEmpty)
        XCTAssertTrue(device.autoExposureBiases.isEmpty)
    }

    func testBiasDroppedWhenManualIsPending() {
        controller.submit(.exposure(.custom(iso: 100, duration: 0.01)))
        controller.submit(.exposure(.bias(1)))
        scheduler.runDue()
        XCTAssertEqual(device.customExposures.count, 1)
        XCTAssertTrue(device.biasChanges.isEmpty)
    }

    func testBiasMergesIntoPendingAuto() {
        controller.submit(.exposure(.auto(bias: 0)))
        controller.submit(.exposure(.bias(1)))
        scheduler.runDue()
        XCTAssertEqual(device.autoExposureBiases, [1])
    }

    func testBiasAppliesInAuto() {
        controller.submit(.exposure(.auto(bias: 0)))
        scheduler.runDue()
        scheduler.advance(by: 0.1)
        controller.submit(.exposure(.bias(-0.7)))
        scheduler.advance(by: 0.1)
        XCTAssertEqual(device.biasChanges.count, 1)
        XCTAssertEqual(device.biasChanges[0], -0.7, accuracy: 1e-6)
        XCTAssertEqual(applied.last?.exposure, .auto(bias: -0.7))
    }

    func testTapMeteringIgnoredInManualExposure() {
        controller.submit(.exposure(.custom(iso: 100, duration: 0.01)))
        scheduler.runDue()
        scheduler.advance(by: 0.1)
        controller.submit(.focus(.continuousAuto(point: CGPoint(x: 0.2, y: 0.3))))
        controller.submit(.exposurePoint(CGPoint(x: 0.2, y: 0.3)))
        scheduler.advance(by: 0.1)
        XCTAssertTrue(device.exposurePoints.isEmpty, "Tap in MANUAL moves focus only")
        XCTAssertEqual(device.focusCommands.last, .continuousAuto(point: CGPoint(x: 0.2, y: 0.3)))
    }

    func testTapMeteringAppliesInAuto() {
        controller.submit(.exposure(.auto(bias: 0)))
        controller.submit(.exposurePoint(CGPoint(x: 1.4, y: -0.2)))
        scheduler.runDue()
        XCTAssertEqual(device.exposurePoints, [CGPoint(x: 1, y: 0)], "Points are clamped to 0…1")
    }

    // MARK: - Clamping

    func testManualExposureClampedToDevice() {
        controller.submit(.exposure(.custom(iso: 10, duration: 5)))
        scheduler.runDue()
        XCTAssertEqual(device.customExposures.last?.iso, 50)
        XCTAssertEqual(device.customExposures.last!.duration, 1.0 / 3, accuracy: 1e-12)
        XCTAssertEqual(applied.last?.exposure, .custom(iso: 50, duration: 1.0 / 3))
    }

    func testWhiteBalanceInputsClamped() {
        controller.submit(.whiteBalance(.locked(temperature: 50000, tint: 500)))
        scheduler.runDue()
        XCTAssertEqual(device.whiteBalanceLocks.last?.temperature, 15000)
        XCTAssertEqual(device.whiteBalanceLocks.last?.tint, 150)
    }

    func testUnsupportedCustomExposureIsSkipped() {
        var limits = device.limits
        limits.supportsCustomExposure = false
        let front = FakeCameraDevice(identifier: "front", limits: limits)
        controller.bind(front)
        controller.submit(.exposure(.custom(iso: 100, duration: 0.01)))
        scheduler.runDue()
        XCTAssertTrue(front.customExposures.isEmpty)
    }

    // MARK: - Lens switch (§8, F15)

    func testLensSwitchReappliesClampedExposureAndReturnsToAutofocus() {
        controller.submit(.exposure(.custom(iso: 5000, duration: 0.01)))
        controller.submit(.whiteBalance(.locked(temperature: 4200, tint: 0)))
        scheduler.runDue()

        var teleLimits = device.limits
        teleLimits.maxISO = 2000
        let tele = FakeCameraDevice(identifier: "tele", limits: teleLimits)
        controller.bind(tele, reapply: true)

        XCTAssertEqual(tele.lockCalls, 1, "Re-applied immediately in one lock")
        XCTAssertEqual(tele.customExposures.last?.iso, 2000)
        XCTAssertEqual(tele.whiteBalanceLocks.last?.temperature, 4200)
        XCTAssertEqual(tele.focusCommands.last, .continuousAuto(point: nil))
    }

    func testLensSwitchKeepsManualFocus() {
        controller.submit(.focus(.locked(lensPosition: 0.3)))
        scheduler.runDue()
        let tele = FakeCameraDevice(identifier: "tele", limits: device.limits)
        controller.bind(tele, reapply: true)
        XCTAssertEqual(tele.focusCommands.last, .locked(lensPosition: 0.3))
    }

    func testResetForgetsRememberedCommands() {
        controller.submit(.exposure(.custom(iso: 800, duration: 0.01)))
        scheduler.runDue()
        controller.resetRemembered()
        let tele = FakeCameraDevice(identifier: "tele", limits: device.limits)
        controller.bind(tele, reapply: true)
        XCTAssertTrue(tele.customExposures.isEmpty)
    }

    // MARK: - Lock failures

    func testLockFailureRetriesThenDrops() {
        var failure: Error?
        controller.onLockFailure = { failure = $0 }
        device.failingLocks = 10
        controller.submit(.exposure(.custom(iso: 100, duration: 0.01)))
        for _ in 0..<10 { scheduler.advance(by: 0.05) }
        XCTAssertEqual(device.lockCalls, 3)
        XCTAssertNotNil(failure)
        XCTAssertTrue(device.customExposures.isEmpty)
        XCTAssertFalse(controller.hasPendingCommands)
    }

    func testLockRecoversAfterTransientFailure() {
        device.failingLocks = 1
        controller.submit(.exposure(.custom(iso: 100, duration: 0.01)))
        scheduler.runDue()
        scheduler.advance(by: 0.05)
        XCTAssertEqual(device.customExposures.count, 1)
    }
}
