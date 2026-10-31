import XCTest
@testable import ManualCameraApp

final class ExposureMathTests: XCTestCase {

    // MARK: - Shutter table

    func testShutterTableClampedToDeviceRange() {
        let stops = ExposureMath.shutterStops(minDuration: 1.0 / 40000, maxDuration: 1.0 / 3)
        XCTAssertEqual(stops.first!, 1.0 / 40000, accuracy: 1e-12)
        XCTAssertEqual(stops.last!, 0.3, accuracy: 1e-12)
        XCTAssertTrue(stops.contains { abs($0 - 1.0 / 125) < 1e-12 })
        XCTAssertEqual(stops, stops.sorted(), "Table must be fastest-first")
    }

    func testShutterTableAddsUnreachableDeviceEndpoints() {
        // 1/45000 is more than 1/6 stop faster than 1/40000, so it becomes the first entry.
        let stops = ExposureMath.shutterStops(minDuration: 1.0 / 45000, maxDuration: 1.0)
        XCTAssertEqual(stops.first!, 1.0 / 45000, accuracy: 1e-12)
        XCTAssertEqual(stops.last!, 1.0, accuracy: 1e-12)
    }

    func testShutterStopsAreOneThirdStopApart() {
        let stops = ExposureMath.shutterStops(minDuration: 1.0 / 8000, maxDuration: 1.0 / 30)
        for (a, b) in zip(stops, stops.dropFirst()) {
            XCTAssertEqual(ExposureMath.stopsBetween(a, b), 1.0 / 3.0, accuracy: 0.12)
        }
    }

    // MARK: - ISO table

    func testISOTable() {
        let stops = ExposureMath.isoStops(minISO: 32, maxISO: 3200)
        XCTAssertEqual(stops.first, 32)
        XCTAssertEqual(stops.last, 3200)
        XCTAssertEqual(stops.count, 21)
    }

    func testISOTableAppendsDeviceMaximum() {
        let stops = ExposureMath.isoStops(minISO: 50, maxISO: 6144)
        XCTAssertEqual(stops.first, 50)
        XCTAssertEqual(stops.last, 6144)
        XCTAssertTrue(stops.contains(5000))
    }

    func testDegenerateRanges() {
        XCTAssertEqual(ExposureMath.isoStops(minISO: 0, maxISO: 0), [])
        XCTAssertEqual(ExposureMath.stops(from: [1, 2, 4], min: 1.5, max: 1.6), [1.5, 1.6])
        XCTAssertEqual(ExposureMath.stops(from: [1, 2, 4], min: 3, max: 3), [3])
    }

    // MARK: - EV table

    func testEVTableLimitedToThreeStops() {
        let stops = ExposureMath.evStops(minBias: -8, maxBias: 8)
        XCTAssertEqual(stops.count, 19)
        XCTAssertEqual(stops.first!, -3, accuracy: 1e-6)
        XCTAssertEqual(stops.last!, 3, accuracy: 1e-6)
        XCTAssertTrue(stops.contains { abs($0) < 1e-6 })
    }

    func testEVTableClampedToDevice() {
        let stops = ExposureMath.evStops(minBias: -2, maxBias: 2)
        XCTAssertEqual(stops.count, 13)
        XCTAssertEqual(stops.first!, -2, accuracy: 1e-6)
    }

    // MARK: - Lookup and log mapping

    func testNearestIndexInLogSpace() {
        let stops = ExposureMath.nominalShutterSpeeds
        let index = ExposureMath.nearestIndex(of: 1.0 / 120, in: stops)
        XCTAssertEqual(stops[index], 1.0 / 125, accuracy: 1e-12)
        XCTAssertEqual(ExposureMath.nearestIndex(of: 0.0, in: stops), 0)
        XCTAssertEqual(ExposureMath.nearestIndex(of: 1.0, in: [Double]()), 0)
    }

    func testNearestISOIndex() {
        let stops: [Float] = [100, 125, 160, 200]
        XCTAssertEqual(ExposureMath.nearestIndex(of: Float(150), in: stops), 2)
        XCTAssertEqual(ExposureMath.nearestLinearIndex(of: 0.4, in: [0, 1.0 / 3, 2.0 / 3]), 1)
    }

    func testLogMappingRoundTrip() {
        for value in [0.001, 0.0042, 0.01, 0.25, 1.0] {
            let fraction = ExposureMath.logFraction(of: value, lower: 0.001, upper: 1)
            XCTAssertEqual(ExposureMath.value(atLogFraction: fraction, lower: 0.001, upper: 1), value, accuracy: value * 1e-9)
        }
        XCTAssertEqual(ExposureMath.logFraction(of: 0.001, lower: 0.001, upper: 1), 0)
        XCTAssertEqual(ExposureMath.logFraction(of: 1, lower: 0.001, upper: 1), 1)
        XCTAssertEqual(ExposureMath.value(atLogFraction: 0.5, lower: 0.001, upper: 1), sqrt(0.001), accuracy: 1e-9)
    }

    func testClamp() {
        XCTAssertEqual(ExposureMath.clamp(5, 0, 3), 3)
        XCTAssertEqual(ExposureMath.clamp(-1, 0, 3), 0)
        XCTAssertEqual(ExposureMath.clamp(2, 0, 3), 2)
        XCTAssertEqual(ExposureMath.clamp(5, 3, 0), 3, "Inverted bounds return the lower bound")
    }

    // MARK: - Formatting

    func testShutterFormatting() {
        XCTAssertEqual(ExposureMath.formatShutter(1.0 / 125), "1/125")
        XCTAssertEqual(ExposureMath.formatShutter(1.0 / 8000), "1/8000")
        XCTAssertEqual(ExposureMath.formatShutter(1.0 / 120.3), "1/120")
        XCTAssertEqual(ExposureMath.formatShutter(0.25), "1/4")
        XCTAssertEqual(ExposureMath.formatShutter(0.3), "0.3s")
        XCTAssertEqual(ExposureMath.formatShutter(0.5), "0.5s")
        XCTAssertEqual(ExposureMath.formatShutter(1), "1s")
        XCTAssertEqual(ExposureMath.formatShutter(2.5), "2.5s")
        XCTAssertEqual(ExposureMath.formatShutter(30), "30s")
        XCTAssertEqual(ExposureMath.formatShutter(0), "—")
        XCTAssertEqual(ExposureMath.formatShutter(.nan), "—")
    }

    func testOtherFormatting() {
        XCTAssertEqual(ExposureMath.formatISO(399.6), "400")
        XCTAssertEqual(ExposureMath.formatEV(0), "±0.0")
        XCTAssertEqual(ExposureMath.formatEV(1.0 / 3.0), "+0.3")
        XCTAssertEqual(ExposureMath.formatEV(-1), "-1.0")
        XCTAssertEqual(ExposureMath.formatKelvin(5480), "5500K")
    }

    // MARK: - White balance

    func testWhiteBalanceGainClamping() {
        let clamped = WhiteBalanceMath.clampGains(.init(red: 0.5, green: 2, blue: 9), maxGain: 4)
        XCTAssertEqual(clamped, .init(red: 1, green: 2, blue: 4))
        let invalid = WhiteBalanceMath.clampGains(.init(red: .nan, green: .infinity, blue: 1.5), maxGain: 4)
        XCTAssertEqual(invalid, .init(red: 1, green: 1, blue: 1.5))
    }
}
