import CoreGraphics
import XCTest
@testable import ManualCameraApp

final class RotationTests: XCTestCase {

    func testGlyphAngleForAllOrientations() {
        XCTAssertEqual(RotationMath.glyphAngle(for: .portrait), 0)
        XCTAssertEqual(RotationMath.glyphAngle(for: .landscapeLeft), 90)
        XCTAssertEqual(RotationMath.glyphAngle(for: .landscapeRight), -90)
        XCTAssertEqual(RotationMath.glyphAngle(for: .portraitUpsideDown), 180)
    }

    func testContinuousAngleTakesShortestPath() {
        XCTAssertEqual(RotationMath.continuousAngle(previous: 90, target: 180), 180)
        XCTAssertEqual(RotationMath.continuousAngle(previous: -90, target: 180), -180)
        XCTAssertEqual(RotationMath.continuousAngle(previous: 0, target: -90), -90)
        XCTAssertEqual(RotationMath.continuousAngle(previous: 270, target: 0), 360)
        XCTAssertEqual(RotationMath.continuousAngle(previous: 0, target: 0), 0)
    }

    func testQuarterTurns() {
        XCTAssertEqual(RotationMath.quarterTurns(forRotationAngle: 0), 0)
        XCTAssertEqual(RotationMath.quarterTurns(forRotationAngle: 90), 1)
        XCTAssertEqual(RotationMath.quarterTurns(forRotationAngle: 180), 2)
        XCTAssertEqual(RotationMath.quarterTurns(forRotationAngle: 270), 3)
        XCTAssertEqual(RotationMath.quarterTurns(forRotationAngle: -90), 3)
        XCTAssertEqual(RotationMath.quarterTurns(forRotationAngle: 360), 0)
    }

    /// Portrait back camera: the buffer is rotated 90° clockwise for display, so the display's
    /// top-left corner shows the buffer's bottom-left corner.
    func testBufferPointPortrait() {
        assertPoint(RotationMath.bufferPoint(forDisplayPoint: CGPoint(x: 0, y: 0), quarterTurns: 1, mirrored: false), CGPoint(x: 0, y: 1))
        assertPoint(RotationMath.bufferPoint(forDisplayPoint: CGPoint(x: 1, y: 0), quarterTurns: 1, mirrored: false), CGPoint(x: 0, y: 0))
        assertPoint(RotationMath.bufferPoint(forDisplayPoint: CGPoint(x: 0.5, y: 0.5), quarterTurns: 1, mirrored: false), CGPoint(x: 0.5, y: 0.5))
    }

    func testBufferPointMirrored() {
        assertPoint(RotationMath.bufferPoint(forDisplayPoint: CGPoint(x: 0.2, y: 0.3), quarterTurns: 0, mirrored: true), CGPoint(x: 0.8, y: 0.3))
    }

    /// The mapping must invert a forward rotation for every quarter turn.
    func testBufferPointInvertsForwardRotation() {
        let samples = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.7, y: 0.9), CGPoint(x: 0.5, y: 0.25)]
        for turns in 0..<4 {
            for buffer in samples {
                let display = forwardRotate(buffer, quarterTurns: turns)
                let back = RotationMath.bufferPoint(forDisplayPoint: display, quarterTurns: turns, mirrored: false)
                assertPoint(back, buffer, "turns \(turns)")
            }
        }
    }

    func testDisplaySize() {
        let size = CGSize(width: 4032, height: 3024)
        XCTAssertEqual(RotationMath.displaySize(forBufferSize: size, quarterTurns: 1), CGSize(width: 3024, height: 4032))
        XCTAssertEqual(RotationMath.displaySize(forBufferSize: size, quarterTurns: 2), size)
    }

    func testScreenRollFromGravity() {
        XCTAssertEqual(RotationMath.screenRollDegrees(gravityX: 0, gravityY: -1), 0, accuracy: 1e-9)
        XCTAssertEqual(RotationMath.screenRollDegrees(gravityX: 1, gravityY: 0), 90, accuracy: 1e-9)
        XCTAssertEqual(RotationMath.screenRollDegrees(gravityX: -1, gravityY: 0), -90, accuracy: 1e-9)
        XCTAssertEqual(RotationMath.screenRollDegrees(gravityX: 0, gravityY: 0), 0)
    }

    func testDeviationFromNearestRightAngle() {
        XCTAssertEqual(RotationMath.deviationFromNearestRightAngle(91), 1, accuracy: 1e-9)
        XCTAssertEqual(RotationMath.deviationFromNearestRightAngle(-89.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(RotationMath.deviationFromNearestRightAngle(44), 44, accuracy: 1e-9)
    }

    func testPitch() {
        XCTAssertEqual(RotationMath.pitchDegrees(gravityX: 0, gravityY: -1, gravityZ: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(RotationMath.pitchDegrees(gravityX: 0, gravityY: 0, gravityZ: -1), 90, accuracy: 1e-9)
    }

    func testFrameOrientationForQuarterTurns() {
        XCTAssertEqual(FramePipeline.orientation(forQuarterTurns: 0), .up)
        XCTAssertEqual(FramePipeline.orientation(forQuarterTurns: 1), .right)
        XCTAssertEqual(FramePipeline.orientation(forQuarterTurns: 2), .down)
        XCTAssertEqual(FramePipeline.orientation(forQuarterTurns: 3), .left)
    }

    // MARK: - Helpers

    /// Buffer → display for a clockwise rotation by `quarterTurns`.
    private func forwardRotate(_ p: CGPoint, quarterTurns: Int) -> CGPoint {
        switch quarterTurns % 4 {
        case 1: return CGPoint(x: 1 - p.y, y: p.x)
        case 2: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 3: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, message, file: file, line: line)
    }
}
