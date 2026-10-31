import AVFoundation

/// Everything that needs the iOS 27 variable-aperture API lives in this file (Slice 2 §7).
///
/// The code is compiled only when the `IOS27_APERTURE_API` compilation condition is set (it is,
/// by default, in the generated project) and runs only on iOS 27+. To build with an older SDK,
/// remove the condition from *Build Settings › Active Compilation Conditions*; the app then treats
/// every lens as fixed-aperture and emulates S with the auto-ISO loop.
enum ApertureSupport {

    /// A typical shutter speed used to ask the format whether a priority combination is supported.
    private static let probeDuration = CMTime(value: 1, timescale: 125)

    static func capability(of device: AVCaptureDevice) -> ExposureCapability {
        var capability = ExposureCapability()
        let current = device.lensAperture
        capability.minAperture = current
        capability.maxAperture = current
        #if IOS27_APERTURE_API
        if #available(iOS 27.0, *) {
            let format = device.activeFormat
            if format.minLensAperture < format.maxLensAperture {
                capability.hasVariableAperture = true
                capability.minAperture = format.minLensAperture
                capability.maxAperture = format.maxLensAperture
                // The iris's recommended stops (ƒ/1.48, 1.8, 2.8, 4 on iPhone 18 Pro).
                let stops = format.recommendedLensApertureStops.filter { stop in
                    format.supportsExposureModeCustom(
                        lensAperture: stop,
                        duration: AVCaptureDevice.autoExposureDuration,
                        iso: AVCaptureDevice.autoISO
                    )
                }
                capability.apertureStops = stops.sorted()
                capability.supportsAperturePriority = !stops.isEmpty
                let probeISO = max(format.minISO, min(100, format.maxISO))
                capability.supportsManualAperture = format.recommendedLensApertureStops.contains { stop in
                    format.supportsExposureModeCustom(lensAperture: stop, duration: probeDuration, iso: probeISO)
                }
            }
            capability.supportsShutterPriority = format.supportsExposureModeCustom(
                lensAperture: current,
                duration: probeDuration,
                iso: AVCaptureDevice.autoISO
            )
        }
        #endif
        return capability
    }

    /// Applies a priority exposure. Must be called with the device locked.
    /// - Returns: false when the API is unavailable (the caller keeps its previous exposure).
    @discardableResult
    static func applyPriority(aperture: Float?, duration: Double?, iso: Float?, to device: AVCaptureDevice) -> Bool {
        #if IOS27_APERTURE_API
        if #available(iOS 27.0, *) {
            let format = device.activeFormat
            let lensAperture: Float
            if let aperture, format.minLensAperture < format.maxLensAperture {
                lensAperture = ExposureMath.clamp(aperture, format.minLensAperture, format.maxLensAperture)
            } else {
                lensAperture = device.lensAperture
            }
            let exposureDuration: CMTime
            if let duration {
                let requested = CMTime(seconds: duration, preferredTimescale: 1_000_000_000)
                exposureDuration = max(min(requested, format.maxExposureDuration), format.minExposureDuration)
            } else {
                exposureDuration = AVCaptureDevice.autoExposureDuration
            }
            let exposureISO: Float = iso.map { ExposureMath.clamp($0, format.minISO, format.maxISO) } ?? AVCaptureDevice.autoISO
            guard format.supportsExposureModeCustom(lensAperture: lensAperture, duration: exposureDuration, iso: exposureISO) else {
                return false
            }
            device.setExposureModeCustom(lensAperture: lensAperture, duration: exposureDuration, iso: exposureISO, completionHandler: nil)
            return true
        }
        #endif
        return false
    }
}
