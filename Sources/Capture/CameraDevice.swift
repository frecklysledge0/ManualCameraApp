import CoreGraphics
import Foundation

/// Hardware limits and capabilities of the active camera, read once per device.
struct DeviceLimits: Equatable, Sendable {
    var minISO: Float = 50
    var maxISO: Float = 3200
    var minDuration: Double = 1.0 / 40000
    var maxDuration: Double = 1.0 / 3
    var minBias: Float = -8
    var maxBias: Float = 8
    var maxWhiteBalanceGain: Float = 4
    var supportsCustomExposure = true
    var supportsLockedFocus = true
    var supportsLockedWhiteBalance = true
    var supportsContinuousAutoFocus = true
    var supportsSingleAutoFocus = true
    var supportsFocusPointOfInterest = true
    var supportsExposurePointOfInterest = true
    /// Fixed or current aperture (ƒ-number) of the lens.
    var aperture: Float = 1.8
    /// Variable aperture and iOS 27 priority-mode support.
    var exposure: ExposureCapability = .fixed
    /// Video frames are Display P3 (wide colour), not BT.709.
    var videoIsP3 = true

    static let `default` = DeviceLimits()

    func clampISO(_ iso: Float) -> Float {
        ExposureMath.clamp(iso, min(minISO, maxISO), max(minISO, maxISO))
    }

    func clampDuration(_ seconds: Double) -> Double {
        ExposureMath.clamp(seconds, min(minDuration, maxDuration), max(minDuration, maxDuration))
    }

    func clampBias(_ bias: Float) -> Float {
        ExposureMath.clamp(bias, min(minBias, maxBias), max(minBias, maxBias))
    }

    func clampAperture(_ aperture: Float) -> Float {
        let lower = min(exposure.minAperture, exposure.maxAperture)
        let upper = max(exposure.minAperture, exposure.maxAperture)
        return ExposureMath.clamp(aperture, lower, upper)
    }

    /// Whether the device accepts `setExposureModeCustom(lensAperture:duration:iso:)` at all.
    var supportsPriorityExposure: Bool {
        exposure.supportsAperturePriority || exposure.supportsShutterPriority || exposure.supportsManualAperture
    }
}

// MARK: - Commands

enum ExposureCommand: Equatable, Sendable {
    /// Continuous auto exposure with the given bias.
    case auto(bias: Float)
    /// Fully manual exposure.
    case custom(iso: Float, duration: Double)
    /// Changes only the bias; ignored while exposure is custom (F7).
    case bias(Float)
    /// iOS 27 priority / aperture exposure. A nil parameter is automatic (nil aperture keeps the
    /// current iris position). The bias applies to whichever parameters are automatic.
    case priority(aperture: Float?, duration: Double?, iso: Float?, bias: Float)
}

enum WhiteBalanceCommand: Equatable, Sendable {
    case auto
    case locked(temperature: Float, tint: Float)
}

enum FocusCommand: Equatable, Sendable {
    /// Continuous AF, optionally at a point of interest (device coordinates 0…1).
    case continuousAuto(point: CGPoint?)
    /// One-shot AF that then holds focus.
    case singleAuto(point: CGPoint?)
    /// Manual focus at a lens position (0 = closest, 1 = farthest).
    case locked(lensPosition: Float)
}

enum DeviceCommand: Equatable, Sendable {
    case exposure(ExposureCommand)
    case whiteBalance(WhiteBalanceCommand)
    case focus(FocusCommand)
    /// Auto-exposure metering point (device coordinates). Ignored while exposure is custom.
    case exposurePoint(CGPoint)
}

// MARK: - Applied state reported back to the UI

enum AppliedExposure: Equatable, Sendable {
    case auto(bias: Float)
    case custom(iso: Float, duration: Double)
    case priority(aperture: Float?, duration: Double?, iso: Float?, bias: Float)

    /// Manual-style exposure: still capture must use `.speed` (F6).
    var isLocked: Bool {
        switch self {
        case .auto: return false
        case .custom, .priority: return true
        }
    }

    /// True when nothing is automatic, so bias and metering points have no effect.
    var isFullyManual: Bool {
        switch self {
        case .auto: return false
        case .custom: return true
        case .priority(_, let duration, let iso, _): return duration != nil && iso != nil
        }
    }
}

struct AppliedWhiteBalance: Equatable, Sendable {
    var isAuto: Bool
    var temperature: Float
    var tint: Float
}

struct AppliedDeviceState: Equatable, Sendable {
    var exposure: AppliedExposure?
    var whiteBalance: AppliedWhiteBalance?
    var focus: FocusCommand?

    var isEmpty: Bool { exposure == nil && whiteBalance == nil && focus == nil }
}

// MARK: - Device abstraction

/// The subset of `AVCaptureDevice` the engine configures. `AVCameraDevice` wraps the real device;
/// tests use a fake so coalescing and the exposure rules can be checked without hardware.
protocol CameraDevice: AnyObject {
    var identifier: String { get }
    var limits: DeviceLimits { get }

    var currentISO: Float { get }
    var currentDuration: Double { get }
    var currentBias: Float { get }
    var currentLensPosition: Float { get }
    var currentAperture: Float { get }
    var exposureTargetOffset: Float { get }
    var currentWhiteBalance: (temperature: Float, tint: Float) { get }

    func lockForConfiguration() throws
    func unlockForConfiguration()

    func applyContinuousAutoExposure(bias: Float)
    func applyExposureBias(_ bias: Float)
    func applyCustomExposure(duration: Double, iso: Float)
    /// iOS 27 `setExposureModeCustom(lensAperture:duration:iso:)`; nil values are automatic.
    func applyPriorityExposure(aperture: Float?, duration: Double?, iso: Float?)
    func applyExposurePoint(_ point: CGPoint)
    func applyAutoWhiteBalance()
    /// Locks white balance and returns the temperature and tint actually achieved after the gains
    /// were clamped to `[1, maxWhiteBalanceGain]`.
    func applyLockedWhiteBalance(temperature: Float, tint: Float) -> (temperature: Float, tint: Float)
    func applyFocus(_ command: FocusCommand)
}
