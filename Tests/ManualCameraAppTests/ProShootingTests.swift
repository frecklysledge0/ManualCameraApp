import CoreGraphics
import XCTest
@testable import ManualCameraApp

/// Slice 2 §12 unit tests: dial tables, the auto-ISO loop, mode rules, the MF gain curve, the
/// focus-snap detector, the level hysteresis, WB presets and profile persistence.
final class ProShootingTests: XCTestCase {

    private let live = LiveExposure(iso: 640, shutter: 1.0 / 60, aperture: 1.48)

    private var variableAperture: ExposureCapability {
        var capability = ExposureCapability()
        capability.hasVariableAperture = true
        capability.apertureStops = [1.48, 1.8, 2.8, 4.0]
        capability.minAperture = 1.48
        capability.maxAperture = 4.0
        capability.supportsAperturePriority = true
        capability.supportsShutterPriority = true
        capability.supportsManualAperture = true
        return capability
    }

    // MARK: - Mode transitions lock the current values (§6)

    func testProgramToManualLocksLiveValues() {
        let values = ExposureRules.transition(from: .program, to: .manual, values: ExposureValues(), live: live)
        XCTAssertEqual(values.iso, 640)
        XCTAssertEqual(values.shutter, 1.0 / 60)
        XCTAssertEqual(values.aperture, 1.48)
        XCTAssertFalse(values.isoAuto)
    }

    func testProgramToShutterPriorityLocksLiveShutter() {
        let values = ExposureRules.transition(from: .program, to: .shutterPriority, values: ExposureValues(), live: live)
        XCTAssertEqual(values.shutter, 1.0 / 60)
    }

    func testManualToShutterPriorityKeepsUserShutter() {
        var stored = ExposureValues()
        stored.shutter = 1.0 / 500
        let values = ExposureRules.transition(from: .manual, to: .shutterPriority, values: stored, live: live)
        XCTAssertEqual(values.shutter, 1.0 / 500)
    }

    func testShutterPriorityToManualKeepsShutterAndLocksISO() {
        var stored = ExposureValues()
        stored.shutter = 1.0 / 250
        let values = ExposureRules.transition(from: .shutterPriority, to: .manual, values: stored, live: live)
        XCTAssertEqual(values.shutter, 1.0 / 250)
        XCTAssertEqual(values.iso, 640)
    }

    func testProgramToAperturePriorityFreezesIris() {
        let values = ExposureRules.transition(from: .program, to: .aperturePriority, values: ExposureValues(), live: live)
        XCTAssertEqual(values.aperture, 1.48)
    }

    func testTransitionFallsBackWhenLiveValuesUnknown() {
        var stored = ExposureValues()
        stored.iso = 200
        let unknown = LiveExposure(iso: 0, shutter: 0, aperture: 0)
        let values = ExposureRules.transition(from: .program, to: .manual, values: stored, live: unknown)
        XCTAssertEqual(values.iso, 200)
    }

    func testApertureModeHiddenWithoutIris() {
        XCTAssertEqual(ExposureCapability.fixed.availablePrograms, [.program, .shutterPriority, .manual])
        XCTAssertEqual(variableAperture.availablePrograms, [.program, .aperturePriority, .shutterPriority, .manual])
    }

    // MARK: - Plans

    func testProgramPlan() {
        var values = ExposureValues()
        values.bias = 0.7
        let plan = ExposureRules.plan(for: .program, values: values, live: live, capability: .fixed)
        XCTAssertEqual(plan, ExposurePlan(command: .auto(bias: 0.7), loop: nil))
    }

    func testShutterPriorityIsEmulatedWithoutIOS27() {
        var values = ExposureValues()
        values.shutter = 1.0 / 500
        let plan = ExposureRules.plan(for: .shutterPriority, values: values, live: live, capability: .fixed)
        XCTAssertEqual(plan.command, .custom(iso: 640, duration: 1.0 / 500))
        XCTAssertEqual(plan.loop, AutoISOLoop(duration: 1.0 / 500, bias: 0, aperture: nil))
    }

    func testShutterPriorityUsesHardwareWhenSupported() {
        var values = ExposureValues()
        values.shutter = 1.0 / 500
        let plan = ExposureRules.plan(for: .shutterPriority, values: values, live: live, capability: variableAperture)
        XCTAssertEqual(plan.command, .priority(aperture: nil, duration: 1.0 / 500, iso: nil, bias: 0))
        XCTAssertNil(plan.loop)
    }

    func testAperturePriorityPlan() {
        var values = ExposureValues()
        values.aperture = 2.8
        let plan = ExposureRules.plan(for: .aperturePriority, values: values, live: live, capability: variableAperture)
        XCTAssertEqual(plan.command, .priority(aperture: 2.8, duration: nil, iso: nil, bias: 0))
    }

    func testManualPlans() {
        var values = ExposureValues()
        values.iso = 400
        values.shutter = 1.0 / 125
        values.aperture = 4
        XCTAssertEqual(ExposureRules.plan(for: .manual, values: values, live: live, capability: .fixed).command, .custom(iso: 400, duration: 1.0 / 125))
        XCTAssertEqual(ExposureRules.plan(for: .manual, values: values, live: live, capability: variableAperture).command,
                       .priority(aperture: 4, duration: 1.0 / 125, iso: 400, bias: 0))
        values.isoAuto = true
        let emulated = ExposureRules.plan(for: .manual, values: values, live: live, capability: .fixed)
        XCTAssertNotNil(emulated.loop, "Auto ISO in M without iOS 27 runs the loop")
        let hardware = ExposureRules.plan(for: .manual, values: values, live: live, capability: variableAperture)
        XCTAssertEqual(hardware.command, .priority(aperture: 4, duration: 1.0 / 125, iso: nil, bias: 0))
    }

    func testQualityPrioritisationPerMode() {
        XCTAssertFalse(ExposureProgram.program.usesSpeedPrioritization)
        XCTAssertTrue(ExposureProgram.aperturePriority.usesSpeedPrioritization)
        XCTAssertTrue(ExposureProgram.shutterPriority.usesSpeedPrioritization)
        XCTAssertTrue(ExposureProgram.manual.usesSpeedPrioritization)
    }

    // MARK: - Auto-ISO loop (§12: converges within 0.1 EV in under 1 s, no oscillation)

    func testAutoISOLoopConvergesWithoutOvershoot() {
        for (start, target) in [(Float(100), Float(800)), (3200, 100), (50, 6000)] {
            let errors = simulateLoop(start: start, target: target, ticks: 15)
            // 15 ticks = 1 s at 15 Hz.
            XCTAssertLessThan(abs(errors.last!), 0.1, "start \(start) target \(target)")
            let firstWithin = errors.firstIndex { abs($0) < 0.1 }
            XCTAssertNotNil(firstWithin)
            XCTAssertLessThan(firstWithin!, 15)
            // No overshoot: the error never changes sign by more than the deadband.
            let sign = errors[0] >= 0 ? 1.0 : -1.0
            XCTAssertTrue(errors.allSatisfy { $0 * sign > -0.05 }, "overshoot for \(start)→\(target): \(errors)")
        }
    }

    func testAutoISOLoopHonoursBiasAndLimits() {
        // Already exposed for the target with +1 EV bias: offset +1 is what we want.
        XCTAssertNil(ExposureLoopMath.nextISO(commanded: 400, observed: 400, meterOffset: 1, bias: 1, minISO: 50, maxISO: 6400))
        // Far too dark at the maximum ISO: stays clamped (returns nil, no change possible).
        XCTAssertNil(ExposureLoopMath.nextISO(commanded: 6400, observed: 6400, meterOffset: -3, bias: 0, minISO: 50, maxISO: 6400))
        let next = ExposureLoopMath.nextISO(commanded: 100, observed: 100, meterOffset: -2, bias: 0, minISO: 50, maxISO: 6400)
        XCTAssertNotNil(next)
        XCTAssertGreaterThan(next!, 100)
    }

    /// Scene needs `target` ISO; the meter reports the frame exposed one tick earlier.
    private func simulateLoop(start: Float, target: Float, ticks: Int) -> [Double] {
        var commanded = start
        var history = [start, start]
        var errors: [Double] = []
        for _ in 0..<ticks {
            let observed = history[history.count - 2]
            let offset = Float(log2(Double(observed / target)))
            if let next = ExposureLoopMath.nextISO(commanded: commanded, observed: observed, meterOffset: offset, bias: 0, minISO: 25, maxISO: 12800) {
                commanded = next
            }
            history.append(commanded)
            errors.append(log2(Double(commanded / target)))
        }
        return errors
    }

    // MARK: - MF wheel gain (§8)

    func testMFGainIsMonotonicAndBounded() {
        var previous = 0.0
        for speed in stride(from: 0.0, through: 4000, by: 25) {
            let gain = FocusMath.gain(forSpeed: speed)
            XCTAssertGreaterThanOrEqual(gain, previous - 1e-12, "speed \(speed)")
            previous = gain
        }
        XCTAssertEqual(FocusMath.gain(forSpeed: 0), FocusMath.fineGain)
        XCTAssertEqual(FocusMath.gain(forSpeed: 10_000), FocusMath.coarseGain, accuracy: 1e-12)
    }

    func testMFExtraResolutionNearInfinity() {
        XCTAssertLessThan(FocusMath.infinityScale(atPosition: 0.95), FocusMath.infinityScale(atPosition: 0.1))
        let nearInfinity = FocusMath.position(after: 10, speed: 0, from: 0.9) - 0.9
        let nearMFD = FocusMath.position(after: 10, speed: 0, from: 0.1) - 0.1
        XCTAssertLessThan(nearInfinity, nearMFD)
    }

    func testMFDirectionAndClamping() {
        XCTAssertGreaterThan(FocusMath.position(after: 50, speed: 100, from: 0.5), 0.5)
        XCTAssertLessThan(FocusMath.position(after: -50, speed: 100, from: 0.5), 0.5)
        XCTAssertEqual(FocusMath.position(after: 10_000, speed: 5000, from: 0.5), 1)
        XCTAssertEqual(FocusMath.position(after: -10_000, speed: 5000, from: 0.5), 0)
        XCTAssertEqual(FocusMath.detentIndex(for: 0.5), 25)
        XCTAssertEqual(FocusMath.detentIndex(for: 1), 50)
    }

    // MARK: - Focus snap (§8)

    func testPeakDetectorFiresOnceAtThePeak() {
        var detector = SharpnessPeakDetector()
        // A pull through focus: rises, peaks at index 6, falls.
        let trace: [Double] = [100, 104, 115, 140, 180, 230, 260, 250, 220, 180, 150, 140]
        let fired = trace.enumerated().filter { detector.add($0.element) }.map(\.offset)
        XCTAssertEqual(fired, [8], "fires on the first sample more than 6% below the peak")
    }

    func testPeakDetectorIgnoresNoise() {
        var detector = SharpnessPeakDetector()
        let noise: [Double] = [100, 103, 98, 104, 101, 97, 102, 99, 103, 100]
        XCTAssertFalse(noise.contains { detector.add($0) })
    }

    func testPeakDetectorFindsTwoPeaks() {
        var detector = SharpnessPeakDetector()
        let trace: [Double] = [100, 150, 200, 150, 100, 90, 130, 180, 220, 160, 120]
        XCTAssertEqual(trace.filter { detector.add($0) }.count, 2)
    }

    func testPeakDetectorReset() {
        var detector = SharpnessPeakDetector()
        _ = detector.add(100)
        _ = detector.add(200)
        detector.reset()
        XCTAssertFalse(detector.add(150), "after reset a drop alone is not a peak")
    }

    // MARK: - Level (§9)

    func testLevelHysteresis() {
        var level = LevelIndicator()
        XCTAssertFalse(level.update(rollDegrees: 2, pitchDegrees: 0))
        XCTAssertTrue(level.update(rollDegrees: 0.4, pitchDegrees: 0), "arriving at level fires once")
        XCTAssertFalse(level.update(rollDegrees: 0.3, pitchDegrees: 0))
        XCTAssertFalse(level.update(rollDegrees: 0.7, pitchDegrees: 0))
        XCTAssertTrue(level.rollIsLevel, "0.7° is still level inside the 0.3° hysteresis")
        XCTAssertFalse(level.update(rollDegrees: 0.9, pitchDegrees: 0))
        XCTAssertFalse(level.rollIsLevel)
        XCTAssertTrue(level.update(rollDegrees: 90.2, pitchDegrees: 0), "landscape counts as level")
        XCTAssertTrue(level.pitchIsLevel)
    }

    // MARK: - White balance (§5)

    func testWhiteBalanceTable() {
        let stops = WhiteBalanceTables.stops
        XCTAssertEqual(stops.first, .auto)
        XCTAssertEqual(Array(stops[1...5]), [.preset(.daylight), .preset(.shade), .preset(.cloudy), .preset(.tungsten), .preset(.fluorescent)])
        XCTAssertEqual(stops[6], .kelvin(2500))
        XCTAssertEqual(stops.last, .kelvin(10000))
        XCTAssertEqual(stops.count, 1 + 5 + 76)
        XCTAssertEqual(WhiteBalanceTables.tintStops.count, 31)
        XCTAssertEqual(WhiteBalanceTables.index(of: .kelvin(5432)), WhiteBalanceTables.index(of: .kelvin(5400)))
        XCTAssertEqual(WhiteBalanceTables.index(of: .kelvin(99999)), stops.count - 1)
    }

    func testWhiteBalancePresetsAndGainClamping() {
        XCTAssertEqual(WhiteBalancePreset.daylight.kelvin, 5500)
        XCTAssertEqual(WhiteBalancePreset.shade.kelvin, 7500)
        XCTAssertEqual(WhiteBalancePreset.cloudy.kelvin, 6500)
        XCTAssertEqual(WhiteBalancePreset.tungsten.kelvin, 3200)
        XCTAssertEqual(WhiteBalancePreset.fluorescent.kelvin, 4000)
        XCTAssertNil(WhiteBalanceStop.auto.kelvinValue)
        // Tungsten needs a large blue gain; it must be clamped to the device maximum.
        let tungstenGains = WhiteBalanceMath.Gains(red: 1.2, green: 1, blue: 5.8)
        XCTAssertEqual(WhiteBalanceMath.clampGains(tungstenGains, maxGain: 4).blue, 4)
        XCTAssertEqual(WhiteBalanceMath.clampGains(.init(red: 0.8, green: 1, blue: 1), maxGain: 4).red, 1)
    }

    // MARK: - Formatting and full stops

    func testApertureFormatting() {
        XCTAssertEqual(ExposureMath.formatAperture(1.48), "ƒ/1.48")
        XCTAssertEqual(ExposureMath.formatAperture(1.8), "ƒ/1.8")
        XCTAssertEqual(ExposureMath.formatAperture(2.8), "ƒ/2.8")
        XCTAssertEqual(ExposureMath.formatAperture(4.0), "ƒ/4")
    }

    func testFullStopDetection() {
        XCTAssertTrue(ExposureMath.isFullStop(shutter: 1.0 / 125))
        XCTAssertFalse(ExposureMath.isFullStop(shutter: 1.0 / 100))
        XCTAssertTrue(ExposureMath.isFullStop(iso: 400))
        XCTAssertFalse(ExposureMath.isFullStop(iso: 500))
    }

    // MARK: - Persistence (§11)

    func testShootingProfileRoundTrip() throws {
        var profile = ShootingProfile()
        profile.program = .shutterPriority
        var values = ExposureValues()
        values.shutter = 1.0 / 1000
        values.bias = -0.3
        profile.setValues(values, for: .shutterPriority)
        profile.focusMode = .manual
        profile.whiteBalance = .preset(.cloudy)
        profile.tint = 20
        profile.overlays.zebrasEnabled = true
        profile.overlays.zebraThreshold = .p90
        profile.overlays.grid = .square
        profile.haptics.intensity = 0.7
        profile.lensKind = .telephoto

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ShootingProfile.self, from: data)
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.values(for: .shutterPriority).shutter, 1.0 / 1000)
    }

    func testShootingProfileToleratesMissingKeys() throws {
        let data = Data(#"{"program":"M","focusMode":"AF-S"}"#.utf8)
        let decoded = try JSONDecoder().decode(ShootingProfile.self, from: data)
        XCTAssertEqual(decoded.program, .manual)
        XCTAssertEqual(decoded.focusMode, .single)
        XCTAssertEqual(decoded.overlays, OverlaySettings())
        XCTAssertTrue(decoded.rawEnabled)
    }

    func testShootingProfilePersistsInUserDefaults() throws {
        let suite = "ProShootingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ShootingProfile.load(from: defaults), ShootingProfile())
        defaults.set(false, forKey: "rawEnabled")
        XCTAssertFalse(ShootingProfile.load(from: defaults).rawEnabled, "Slice 1 RAW toggle is carried over")
        var profile = ShootingProfile()
        profile.program = .manual
        profile.save(to: defaults)
        XCTAssertEqual(ShootingProfile.load(from: defaults).program, .manual)
    }

    // MARK: - Priority exposure in the device controller

    func testPriorityExposureIsClampedAndBiasApplies() {
        let scheduler = FakeScheduler()
        let controller = DeviceController(scheduler: scheduler)
        var limits = DeviceLimits()
        limits.exposure = variableAperture
        limits.minISO = 50
        limits.maxISO = 6400
        let device = FakeCameraDevice(identifier: "main", limits: limits)
        controller.bind(device)

        controller.submit(.exposure(.priority(aperture: 8, duration: nil, iso: nil, bias: 0.3)))
        scheduler.runDue()
        XCTAssertEqual(device.priorityExposures.count, 1)
        XCTAssertEqual(device.priorityExposures[0].aperture, 4, "clamped to the widest-to-narrowest range")
        XCTAssertNil(device.priorityExposures[0].duration)
        XCTAssertEqual(device.biasChanges.last!, 0.3, accuracy: 1e-6)
        XCTAssertTrue(controller.exposureState?.isLocked ?? false, "A/S/M capture uses .speed")

        scheduler.advance(by: 0.1)
        controller.submit(.exposure(.bias(-1)))
        scheduler.advance(by: 0.1)
        XCTAssertEqual(device.biasChanges.last!, -1, accuracy: 1e-6, "EV still biases the automatic part")
    }

    func testPriorityIgnoredWithoutSupport() {
        let scheduler = FakeScheduler()
        let controller = DeviceController(scheduler: scheduler)
        let device = FakeCameraDevice()
        controller.bind(device)
        controller.submit(.exposure(.priority(aperture: 2.8, duration: nil, iso: nil, bias: 0)))
        scheduler.runDue()
        XCTAssertTrue(device.priorityExposures.isEmpty)
    }

    func testFullyManualPriorityIgnoresMetering() {
        let scheduler = FakeScheduler()
        let controller = DeviceController(scheduler: scheduler)
        var limits = DeviceLimits()
        limits.exposure = variableAperture
        let device = FakeCameraDevice(identifier: "main", limits: limits)
        controller.bind(device)
        controller.submit(.exposure(.priority(aperture: 2.8, duration: 0.01, iso: 200, bias: 0)))
        controller.submit(.exposurePoint(CGPoint(x: 0.3, y: 0.3)))
        scheduler.runDue()
        XCTAssertTrue(device.exposurePoints.isEmpty)
        XCTAssertTrue(device.biasChanges.isEmpty)
    }
}
