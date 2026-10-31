import Foundation
import Observation

/// What the user has chosen (Slice 2). Views read and write this optimistically on the main
/// thread; the engine writes back the values it actually applied. It is the single source of
/// truth for the lens and the camera position (F15).
@Observable
@MainActor
final class CameraSettings {

    // MARK: HUD state
    var activeTile: FnTile?
    var showFnSheet = false
    var histogramExpanded = false
    var loupeZoom: Int = 4

    // MARK: Exposure
    var program: ExposureProgram = .program
    /// Values of the current program (each program remembers its own in `profile.modeValues`).
    var exposure = ExposureValues()

    // MARK: White balance
    var whiteBalance: WhiteBalanceStop = .auto
    var tint: Float = 0

    // MARK: Focus
    var focusMode: FocusMode = .continuous
    var lensPosition: Float = 0.5

    // MARK: Lens
    var lens: LensOption?
    var lenses: [LensOption] = []
    var lastBackLens: LensOption?
    var limits: DeviceLimits = .default

    // MARK: Capture format
    var rawSupported = false
    /// What the user wants to save (Fn › Format).
    var captureFormat: CaptureFormat = .raw
    var rawSuppressedForStorage = false

    // MARK: Overlays and feedback
    var overlays = OverlaySettings()
    var haptics = HapticSettings()
    var theme: ThemeID = .alpha

    // MARK: Medium Format Edition (Slice 3)
    var framing: FramingMode = .native
    var grain: GrainLevel = .fine
    var shutterSound: ShutterSoundVolume = .low
    var previewGrain = false
    /// Debug-only performance read-out (feed fps, UI fps, shutter lag).
    var showPerformanceHUD = false

    var isEdition: Bool { theme == .edition }

    // MARK: Derived

    var isFrontCamera: Bool { lens?.isFront ?? false }

    /// The format actually used: RAW needs hardware support and enough free space.
    var effectiveFormat: CaptureFormat {
        guard captureFormat.includesRaw, rawSupported, !rawSuppressedForStorage else { return .heif }
        return captureFormat
    }

    var effectiveRaw: Bool { effectiveFormat.includesRaw }

    var backLenses: [LensOption] { lenses.filter { !$0.isFront } }

    var capability: ExposureCapability { limits.exposure }

    var availablePrograms: [ExposureProgram] { capability.availablePrograms }

    /// Peaking is on automatically in MF and opt-in in AF (§8).
    var peakingActive: Bool { focusMode == .manual || overlays.peakingInAF }

    var shutterStops: [Double] {
        ExposureMath.shutterStops(minDuration: limits.minDuration, maxDuration: limits.maxDuration)
    }

    var isoStops: [Float] {
        ExposureMath.isoStops(minISO: limits.minISO, maxISO: limits.maxISO)
    }

    var evStops: [Float] {
        ExposureMath.evStops(minBias: limits.minBias, maxBias: limits.maxBias, limit: 3)
    }

    var apertureStops: [Float] { capability.apertureStops }

    /// Whether EV is the metered-manual read-out (M with fixed ISO) rather than a bias dial.
    var evIsMeteredManual: Bool { program == .manual && !exposure.isoAuto }

    func isAutomatic(_ tile: FnTile) -> Bool {
        switch tile {
        case .mode: return program == .program
        case .aperture: return capability.hasVariableAperture && (program == .program || program == .shutterPriority)
        case .shutter: return program == .program || program == .aperturePriority
        case .iso: return program != .manual || exposure.isoAuto
        case .ev: return false
        case .whiteBalance: return whiteBalance == .auto
        case .focus: return focusMode != .manual
        }
    }

    /// Restores everything from a saved profile.
    func apply(_ profile: ShootingProfile) {
        program = profile.program
        exposure = profile.values(for: profile.program)
        whiteBalance = profile.whiteBalance
        tint = profile.tint
        focusMode = profile.focusMode
        overlays = profile.overlays
        captureFormat = profile.captureFormat
        haptics = profile.haptics
        theme = profile.theme
        framing = profile.framing
        grain = profile.grain
        shutterSound = profile.shutterSound
        previewGrain = profile.previewGrain
    }

    /// Writes the current state into `profile` (keeps other modes' values).
    func store(into profile: inout ShootingProfile) {
        profile.program = program
        profile.setValues(exposure, for: program)
        profile.whiteBalance = whiteBalance
        profile.tint = tint
        profile.focusMode = focusMode
        profile.overlays = overlays
        profile.captureFormat = captureFormat
        profile.haptics = haptics
        profile.theme = theme
        profile.framing = framing
        profile.grain = grain
        profile.shutterSound = shutterSound
        profile.previewGrain = previewGrain
        if let lens, !lens.isFront { profile.lensKind = lens.kind }
    }
}
