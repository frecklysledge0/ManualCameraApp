import CoreGraphics
import Foundation

/// How the phone is physically held. Mirrors the four flat-free cases of `UIDeviceOrientation`
/// without importing UIKit, so the maths stays testable.
enum PhysicalOrientation: String, Codable, Sendable, CaseIterable {
    case portrait
    case portraitUpsideDown
    /// Device rotated 90° counter-clockwise (top of the phone on the left).
    case landscapeLeft
    /// Device rotated 90° clockwise (top of the phone on the right).
    case landscapeRight
}

enum RotationMath {

    /// Rotation (degrees, clockwise-positive as in SwiftUI `rotationEffect`) that keeps a glyph upright
    /// while the interface stays locked to portrait.
    static func glyphAngle(for orientation: PhysicalOrientation) -> Double {
        switch orientation {
        case .portrait: return 0
        case .landscapeLeft: return 90
        case .landscapeRight: return -90
        case .portraitUpsideDown: return 180
        }
    }

    /// Picks the representation of `target` (mod 360) closest to `previous`, so an animated
    /// rotation always takes the short way round (e.g. 90° → 180° rather than 90° → -180°).
    static func continuousAngle(previous: Double, target: Double) -> Double {
        var delta = (target - previous).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return previous + delta
    }

    /// Number of clockwise quarter turns for a connection rotation angle (0, 90, 180, 270).
    static func quarterTurns(forRotationAngle degrees: Double) -> Int {
        let turns = Int((degrees / 90).rounded()) % 4
        return turns < 0 ? turns + 4 : turns
    }

    /// Maps a normalised point on the displayed (rotated, optionally mirrored) image back to the
    /// normalised coordinate in the unrotated sensor buffer. `quarterTurns` is the clockwise
    /// rotation applied to the buffer to display it. The Metal shaders use the same mapping.
    static func bufferPoint(forDisplayPoint display: CGPoint, quarterTurns: Int, mirrored: Bool) -> CGPoint {
        let u = mirrored ? 1 - display.x : display.x
        let v = display.y
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGPoint(x: v, y: 1 - u)
        case 2: return CGPoint(x: 1 - u, y: 1 - v)
        case 3: return CGPoint(x: 1 - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }

    /// Size of the buffer after rotating it by `quarterTurns` clockwise quarter turns.
    static func displaySize(forBufferSize size: CGSize, quarterTurns: Int) -> CGSize {
        quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Horizon angle in the screen plane from a gravity vector in device coordinates
    /// (x to the right of the screen, y towards the top). Positive when the phone is rotated clockwise.
    /// Returns degrees in (-180, 180].
    static func screenRollDegrees(gravityX: Double, gravityY: Double) -> Double {
        guard gravityX != 0 || gravityY != 0 else { return 0 }
        return atan2(gravityX, -gravityY) * 180 / .pi
    }

    /// Deviation from the nearest 90° orientation, used to judge "level" in any orientation.
    static func deviationFromNearestRightAngle(_ degrees: Double) -> Double {
        degrees - (degrees / 90).rounded() * 90
    }

    /// Forward/back tilt in degrees: 0 when the phone is vertical, positive when the top leans away.
    static func pitchDegrees(gravityX: Double, gravityY: Double, gravityZ: Double) -> Double {
        let planar = (gravityX * gravityX + gravityY * gravityY).squareRoot()
        guard planar > 0 || gravityZ != 0 else { return 0 }
        return atan2(-gravityZ, planar) * 180 / .pi
    }
}
