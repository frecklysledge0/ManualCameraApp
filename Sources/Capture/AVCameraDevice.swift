import AVFoundation
import CoreGraphics

/// `CameraDevice` backed by a real `AVCaptureDevice`. Every setter checks support first and clamps
/// to the active format, because AVFoundation raises Objective-C exceptions (crashes) for
/// out-of-range exposure durations, ISO, bias and white-balance gains.
final class AVCameraDevice: CameraDevice {

    let device: AVCaptureDevice
    let limits: DeviceLimits

    init(device: AVCaptureDevice) {
        self.device = device
        self.limits = Self.readLimits(of: device)
    }

    static func readLimits(of device: AVCaptureDevice) -> DeviceLimits {
        let format = device.activeFormat
        var limits = DeviceLimits()
        limits.minISO = format.minISO
        limits.maxISO = format.maxISO
        let minSeconds = format.minExposureDuration.seconds
        let maxSeconds = format.maxExposureDuration.seconds
        if minSeconds.isFinite, minSeconds > 0 { limits.minDuration = minSeconds }
        if maxSeconds.isFinite, maxSeconds > 0 { limits.maxDuration = maxSeconds }
        limits.minBias = device.minExposureTargetBias
        limits.maxBias = device.maxExposureTargetBias
        limits.maxWhiteBalanceGain = device.maxWhiteBalanceGain
        limits.supportsCustomExposure = device.isExposureModeSupported(.custom)
        limits.supportsLockedFocus = device.isLockingFocusWithCustomLensPositionSupported
        limits.supportsLockedWhiteBalance = device.isWhiteBalanceModeSupported(.locked)
            && device.isLockingWhiteBalanceWithCustomDeviceGainsSupported
        limits.supportsContinuousAutoFocus = device.isFocusModeSupported(.continuousAutoFocus)
        limits.supportsSingleAutoFocus = device.isFocusModeSupported(.autoFocus)
        limits.supportsFocusPointOfInterest = device.isFocusPointOfInterestSupported
        limits.supportsExposurePointOfInterest = device.isExposurePointOfInterestSupported
        limits.aperture = device.lensAperture
        limits.exposure = ApertureSupport.capability(of: device)
        limits.videoIsP3 = device.activeColorSpace == .P3_D65
        return limits
    }

    // MARK: - Current values

    var identifier: String { device.uniqueID }
    var currentISO: Float { device.iso }

    var currentDuration: Double {
        let seconds = device.exposureDuration.seconds
        return seconds.isFinite ? seconds : limits.minDuration
    }

    var currentBias: Float { device.exposureTargetBias }
    var currentLensPosition: Float { device.lensPosition }
    var currentAperture: Float { device.lensAperture }
    var exposureTargetOffset: Float { device.exposureTargetOffset }

    var currentWhiteBalance: (temperature: Float, tint: Float) {
        let gains = device.deviceWhiteBalanceGains
        let safe = WhiteBalanceMath.clampGains(
            .init(red: gains.redGain, green: gains.greenGain, blue: gains.blueGain),
            maxGain: device.maxWhiteBalanceGain
        )
        let values = device.temperatureAndTintValues(
            for: AVCaptureDevice.WhiteBalanceGains(redGain: safe.red, greenGain: safe.green, blueGain: safe.blue)
        )
        return (values.temperature, values.tint)
    }

    // MARK: - Configuration

    func lockForConfiguration() throws {
        try device.lockForConfiguration()
    }

    func unlockForConfiguration() {
        device.unlockForConfiguration()
    }

    func applyContinuousAutoExposure(bias: Float) {
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        applyExposureBias(bias)
    }

    func applyExposureBias(_ bias: Float) {
        let clamped = ExposureMath.clamp(bias, device.minExposureTargetBias, device.maxExposureTargetBias)
        device.setExposureTargetBias(clamped, completionHandler: nil)
    }

    func applyCustomExposure(duration: Double, iso: Float) {
        guard device.isExposureModeSupported(.custom) else { return }
        let format = device.activeFormat
        let requested = CMTime(seconds: duration, preferredTimescale: 1_000_000_000)
        // Clamp in CMTime so rounding can never push the value outside the format's range.
        let safeDuration = max(min(requested, format.maxExposureDuration), format.minExposureDuration)
        let safeISO = ExposureMath.clamp(iso, format.minISO, format.maxISO)
        device.setExposureModeCustom(duration: safeDuration, iso: safeISO, completionHandler: nil)
    }

    func applyPriorityExposure(aperture: Float?, duration: Double?, iso: Float?) {
        if ApertureSupport.applyPriority(aperture: aperture, duration: duration, iso: iso, to: device) {
            return
        }
        // Without the iOS 27 API a fully specified exposure still works as plain custom exposure.
        if let duration, let iso {
            applyCustomExposure(duration: duration, iso: iso)
        }
    }

    func applyExposurePoint(_ point: CGPoint) {
        guard device.isExposurePointOfInterestSupported else { return }
        device.exposurePointOfInterest = point
        // The point only takes effect when the exposure mode is set again.
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    func applyAutoWhiteBalance() {
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    func applyLockedWhiteBalance(temperature: Float, tint: Float) -> (temperature: Float, tint: Float) {
        guard device.isWhiteBalanceModeSupported(.locked),
              device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else {
            return currentWhiteBalance
        }
        let target = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint)
        let raw = device.deviceWhiteBalanceGains(for: target)
        let safe = WhiteBalanceMath.clampGains(
            .init(red: raw.redGain, green: raw.greenGain, blue: raw.blueGain),
            maxGain: device.maxWhiteBalanceGain
        )
        let gains = AVCaptureDevice.WhiteBalanceGains(redGain: safe.red, greenGain: safe.green, blueGain: safe.blue)
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        let achieved = device.temperatureAndTintValues(for: gains)
        return (achieved.temperature, achieved.tint)
    }

    func applyFocus(_ command: FocusCommand) {
        switch command {
        case .continuousAuto(let point):
            if let point, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            // The AF point stays where the user put it (Sony-style flexible spot); no auto-recentring.
            device.isSubjectAreaChangeMonitoringEnabled = false
        case .singleAuto(let point):
            if let point, device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }
            device.isSubjectAreaChangeMonitoringEnabled = false
        case .locked(let lensPosition):
            device.isSubjectAreaChangeMonitoringEnabled = false
            if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: ExposureMath.clamp(lensPosition, 0, 1), completionHandler: nil)
            } else if device.isFocusModeSupported(.locked) {
                device.focusMode = .locked
            }
        }
    }
}
