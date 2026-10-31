import AVFoundation
import Foundation
import Metal
import Photos
import QuartzCore
import UIKit

/// Runs `body` on the main actor: immediately when already on the main thread, otherwise on the
/// next main-queue turn.
func runOnMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }
}

/// The app's intents. Views call these methods and read the three state objects; the controller
/// updates state optimistically, sends commands to the engine and folds the engine's events back
/// into state. It is the only type that talks to both the UI state and `CaptureEngine`.
@MainActor
final class CameraController {

    let settings: CameraSettings
    let telemetry: LiveTelemetry
    let status: CaptureStatus
    let haptics: HapticsEngine

    private let engine: CaptureEngine
    private let motion = MotionSampler()
    private let defaults: UserDefaults
    private weak var previewView: PreviewView?
    private var notificationTokens: [NSObjectProtocol] = []
    private var focusTapCounter = 0
    private var hasStarted = false
    private var expectingLensSwitchHaptic = false
    #if DEBUG
    private let frameProbe = FrameRateProbe()
    #endif

    var metalDevice: MTLDevice? { engine.pipeline.metalDevice }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = CameraSettings(defaults: defaults)
        telemetry = LiveTelemetry()
        status = CaptureStatus()
        haptics = HapticsEngine()
        engine = CaptureEngine()

        settings.lenses = engine.catalog.allLenses
        settings.lens = engine.catalog.defaultLens
        settings.lastBackLens = engine.catalog.defaultLens

        engine.onEvent = { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handle(event)
            }
        }
        engine.pipeline.onHistogram = { [weak self] sample in
            guard let self else { return }
            runOnMain { self.telemetry.histogram = sample }
        }
        motion.onReading = { [weak self] reading in
            guard let self else { return }
            runOnMain {
                self.telemetry.rollDegrees = reading.rollDegrees
                self.telemetry.pitchDegrees = reading.pitchDegrees
            }
        }
        observeSystem()
        #if DEBUG
        frameProbe.onRate = { [weak self] rate in
            guard let self else { return }
            runOnMain { self.telemetry.uiFPS = rate }
        }
        #endif
    }

    // MARK: - Lifecycle

    /// Checks permissions and starts the camera. Safe to call more than once.
    func start() {
        guard !hasStarted, !Self.isRunningTests else { return }
        hasStarted = true
        #if DEBUG
        frameProbe.start()
        #endif
        requestCameraAccess()
    }

    func sceneBecameActive() {
        haptics.resume()
        guard status.authorization == .authorized else {
            // Permission may have been granted in Settings while we were away.
            if hasStarted { refreshAuthorization() }
            return
        }
        engine.resume()
        if settings.showGrid { motion.start() }
        checkStorage()
        checkPhotosAccess(request: false)
    }

    func sceneEnteredBackground() {
        engine.suspend()
        motion.stop()
    }

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                runOnMain {
                    if granted {
                        self.cameraAuthorized()
                    } else {
                        self.status.authorization = .denied
                    }
                }
            }
        case .denied:
            status.authorization = .denied
        case .restricted:
            status.authorization = .restricted
        @unknown default:
            status.authorization = .denied
        }
    }

    private func refreshAuthorization() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            cameraAuthorized()
        }
    }

    private func cameraAuthorized() {
        let firstTime = status.authorization != .authorized
        status.authorization = .authorized
        guard firstTime else { return }
        if settings.lenses.isEmpty {
            status.show(Banner(kind: .noCamera, message: "No camera found on this device.", action: .none))
            return
        }
        engine.start(lens: settings.lens, rawEnabled: settings.effectiveRaw)
        checkPhotosAccess(request: true)
        checkStorage()
        updateThermal()
    }

    private func checkPhotosAccess(request: Bool) {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .notDetermined {
            guard request else { return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] _ in
                guard let self else { return }
                runOnMain { self.checkPhotosAccess(request: false) }
            }
            return
        }
        if current == .authorized || current == .limited {
            status.dismiss(.photosDenied)
        } else {
            status.show(Banner(
                kind: .photosDenied,
                message: "Photos access is off. Shots are saved to Files › ManualCameraApp.",
                action: .openSettings
            ))
        }
    }

    // MARK: - Preview

    func attachPreview(_ view: PreviewView) {
        previewView = view
        engine.attach(previewLayer: view.videoPreviewLayer)
        engine.pipeline.attachOverlay(view.overlayView.metalLayer)
        view.onTap = { [weak self] point, devicePoint in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.focus(atViewPoint: point, devicePoint: devicePoint)
            }
        }
        view.onGeometryChange = { [weak self] geometry in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.status.viewfinder = geometry
            }
        }
    }

    // MARK: - Panels

    func select(_ panel: ControlPanel) {
        guard panel != settings.panel || panel == .auto else { return }
        settings.panel = panel
        switch panel {
        case .auto:
            settings.exposureMode = .auto
            settings.bias = 0
            settings.whiteBalanceAuto = true
            settings.focusManual = false
            engine.resetToAuto()
        case .manual:
            if settings.exposureMode != .manual {
                settings.exposureMode = .manual
                // Start from what the camera is doing now so the image does not jump (F8).
                if telemetry.liveISO > 0 { settings.iso = telemetry.liveISO }
                if telemetry.liveShutter > 0 { settings.shutter = telemetry.liveShutter }
                engine.enterManualExposure()
            }
        case .ev:
            break
        case .whiteBalance:
            if settings.whiteBalanceAuto, telemetry.liveTemperature > 0 {
                settings.temperature = telemetry.liveTemperature
            }
        case .focus:
            if !settings.focusManual, telemetry.liveLensPosition > 0 {
                settings.lensPosition = telemetry.liveLensPosition
            }
        }
        setPeaking(panel == .focus)
    }

    private func setPeaking(_ enabled: Bool) {
        settings.peakingEnabled = enabled
        engine.pipeline.updateConfig { $0.peakingEnabled = enabled }
    }

    // MARK: - Exposure, white balance, focus

    func setShutter(_ seconds: Double) {
        guard settings.exposureMode == .manual else { return }
        settings.shutter = settings.limits.clampDuration(seconds)
        engine.send(.exposure(.custom(iso: settings.iso, duration: settings.shutter)))
    }

    func setISO(_ iso: Float) {
        guard settings.exposureMode == .manual else { return }
        settings.iso = settings.limits.clampISO(iso)
        engine.send(.exposure(.custom(iso: settings.iso, duration: settings.shutter)))
    }

    /// EV is active only in AUTO exposure (F7).
    func setBias(_ bias: Float) {
        guard settings.exposureMode == .auto else { return }
        settings.bias = settings.limits.clampBias(bias)
        engine.send(.exposure(.bias(settings.bias)))
    }

    func setTemperature(_ kelvin: Float) {
        settings.whiteBalanceAuto = false
        settings.temperature = kelvin
        engine.send(.whiteBalance(.locked(temperature: kelvin, tint: settings.tint)))
    }

    func resetWhiteBalance() {
        settings.whiteBalanceAuto = true
        engine.send(.whiteBalance(.auto))
    }

    func setLensPosition(_ position: Float) {
        settings.focusManual = true
        settings.lensPosition = ExposureMath.clamp(position, 0, 1)
        engine.send(.focus(.locked(lensPosition: settings.lensPosition)))
    }

    /// Tap-to-focus. In manual exposure only focus moves (F7); a tap also leaves manual focus.
    func focus(atViewPoint point: CGPoint, devicePoint: CGPoint) {
        settings.focusManual = false
        engine.send(.focus(.continuousAuto(point: devicePoint)))
        if settings.exposureMode == .auto {
            engine.send(.exposurePoint(devicePoint))
        }
        focusTapCounter += 1
        status.focusIndicator = FocusIndicator(point: status.viewfinder.clampedToVideo(point), id: focusTapCounter)
        let tapID = focusTapCounter
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.status.focusIndicator?.id == tapID {
                    self.status.focusIndicator = nil
                }
            }
        }
    }

    // MARK: - Lenses

    func switchLens(_ lens: LensOption) {
        guard lens != settings.lens, !status.isSwitchingLens else { return }
        status.isSwitchingLens = true
        expectingLensSwitchHaptic = true
        if !lens.isFront { settings.lastBackLens = lens }
        // F15: focus returns to AF on a lens change unless the user is in MF.
        engine.switchLens(to: lens)
        // Safety net: never leave the snapshot up if the first frame is late.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.status.isSwitchingLens { self.finishLensSwitch() }
            }
        }
    }

    func toggleFrontCamera() {
        if settings.isFrontCamera {
            if let back = settings.lastBackLens ?? engine.catalog.defaultLens { switchLens(back) }
        } else if let front = engine.catalog.frontLens {
            switchLens(front)
        }
    }

    private func finishLensSwitch() {
        previewView?.hideSnapshot()
        status.isSwitchingLens = false
    }

    // MARK: - Capture options

    func toggleRaw() {
        guard settings.rawSupported else {
            haptics.play(.limit)
            return
        }
        settings.rawEnabled.toggle()
        defaults.set(settings.rawEnabled, forKey: CameraSettings.rawEnabledKey)
        engine.setRawEnabled(settings.effectiveRaw)
    }

    func toggleGrid() {
        settings.showGrid.toggle()
        if settings.showGrid { motion.start() } else { motion.stop() }
    }

    func shutterPressed() {
        guard status.canCapture else {
            haptics.play(.limit)
            return
        }
        haptics.play(.shutterPress)
        engine.capture(raw: settings.effectiveRaw, pressTime: ProcessInfo.processInfo.systemUptime)
    }

    func openGallery() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
    }

    func perform(_ action: Banner.Action, for kind: Banner.Kind) {
        switch action {
        case .none:
            status.dismiss(kind)
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        case .retrySave:
            engine.retryPendingSaves()
        case .retrySession:
            status.dismiss(kind)
            engine.retrySession()
        }
    }

    // MARK: - Engine events

    private func handle(_ event: CaptureEngine.Event) {
        switch event {
        case .noCamera:
            status.show(Banner(kind: .noCamera, message: "The camera could not be started.", action: .retrySession))

        case .configured(let lens, let limits, let rawSupported):
            settings.lens = lens
            if !lens.isFront { settings.lastBackLens = lens }
            settings.limits = limits
            settings.rawSupported = rawSupported
            settings.iso = limits.clampISO(settings.iso)
            settings.shutter = limits.clampDuration(settings.shutter)
            settings.bias = limits.clampBias(settings.bias)
            engine.setRawEnabled(settings.effectiveRaw)
            previewView?.refreshGeometry()
            if expectingLensSwitchHaptic {
                expectingLensSwitchHaptic = false
                haptics.play(.lensSwitch)
            }

        case .applied(let applied):
            apply(applied)

        case .live(let values):
            telemetry.liveISO = values.iso
            telemetry.liveShutter = values.shutter
            telemetry.liveLensPosition = values.lensPosition
            telemetry.liveTemperature = values.temperature
            telemetry.liveAperture = values.aperture
            telemetry.meterOffset = values.meterOffset

        case .readiness(let ready):
            status.isReady = ready

        case .running(let running):
            status.isSessionRunning = running
            if running { status.dismiss(.sessionFailed) }

        case .interrupted(let reason):
            status.interruption = reason

        case .interruptionEnded:
            status.interruption = nil

        case .sessionFailed(let message):
            status.show(Banner(kind: .sessionFailed, message: message, action: .retrySession))

        case .snapshot(let image):
            // A late snapshot (after the new lens's first frame) must not cover the live image.
            if status.isSwitchingLens { previewView?.showSnapshot(image) }

        case .firstFrameAfterSwitch:
            finishLensSwitch()

        case .willCapture(let latency):
            status.flashCounter += 1
            telemetry.lastLatencyMS = latency

        case .captureStarted:
            status.inFlightCount += 1

        case .captureFinished(let outcome, let thumbnail):
            status.inFlightCount = max(0, status.inFlightCount - 1)
            switch outcome {
            case .saved(let destination, _):
                if let thumbnail { status.lastThumbnail = thumbnail }
                haptics.play(.saved)
                if case .documents = destination { checkPhotosAccess(request: false) }
            case .savePending:
                status.show(Banner(kind: .saveFailed, message: "A photo couldn't be saved. It is kept on the phone.", action: .retrySave))
            case .failed:
                haptics.play(.limit)
            }
            checkStorage()

        case .previewAngle(let angle):
            engine.applyPreviewAngle(angle)

        case .feedRate(let rate):
            telemetry.feedFPS = rate

        case .pendingSaves(let count):
            status.pendingSaveCount = count
            if count > 0 {
                status.show(Banner(kind: .saveFailed, message: "\(count) photo\(count == 1 ? "" : "s") waiting to be saved.", action: .retrySave))
            } else {
                status.dismiss(.saveFailed)
            }
        }
    }

    private func apply(_ applied: AppliedDeviceState) {
        if let exposure = applied.exposure {
            switch exposure {
            case .auto(let bias):
                if settings.exposureMode == .auto { settings.bias = bias }
            case .custom(let iso, let duration):
                if settings.exposureMode == .manual {
                    settings.iso = iso
                    settings.shutter = duration
                }
            }
        }
        if let whiteBalance = applied.whiteBalance {
            settings.whiteBalanceAuto = whiteBalance.isAuto
            if !whiteBalance.isAuto {
                settings.temperature = whiteBalance.temperature
                settings.tint = whiteBalance.tint
            }
        }
        if let focus = applied.focus {
            switch focus {
            case .locked(let position):
                settings.focusManual = true
                settings.lensPosition = position
            case .continuousAuto, .singleAuto:
                settings.focusManual = false
            }
        }
    }

    // MARK: - System observers

    private func observeSystem() {
        let center = NotificationCenter.default
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        notificationTokens.append(center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.updateOrientation() }
        })
        notificationTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.updateThermal() }
        })
    }

    private func updateOrientation() {
        let orientation: PhysicalOrientation
        switch UIDevice.current.orientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: return // face up/down and unknown keep the last orientation
        }
        guard orientation != telemetry.orientation else { return }
        telemetry.orientation = orientation
        telemetry.glyphAngle = RotationMath.continuousAngle(
            previous: telemetry.glyphAngle,
            target: RotationMath.glyphAngle(for: orientation)
        )
    }

    private func updateThermal() {
        let level: ThermalLevel
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: level = .nominal
        case .fair: level = .fair
        case .serious: level = .serious
        case .critical: level = .critical
        @unknown default: level = .serious
        }
        engine.setThermalLevel(level)
        if level >= .critical {
            status.show(Banner(kind: .thermal, message: "iPhone is hot. Preview slowed to 30 fps.", action: .none))
        } else {
            status.dismiss(.thermal)
        }
    }

    /// Free-space policy (§11).
    private func checkStorage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let level = StoragePolicy.level(forAvailableBytes: values?.volumeAvailableCapacityForImportantUsage)
            guard let self else { return }
            runOnMain { self.applyStorage(level) }
        }
    }

    private func applyStorage(_ level: StoragePolicy.Level) {
        let wasSuppressed = settings.rawSuppressedForStorage
        switch level {
        case .ok:
            settings.rawSuppressedForStorage = false
            status.dismiss(.lowStorage)
            status.dismiss(.criticalStorage)
        case .low:
            settings.rawSuppressedForStorage = false
            status.dismiss(.criticalStorage)
            status.show(Banner(kind: .lowStorage, message: "Less than 500 MB free.", action: .none))
        case .critical:
            settings.rawSuppressedForStorage = true
            status.dismiss(.lowStorage)
            status.show(Banner(kind: .criticalStorage, message: "Under 150 MB free: RAW is off until space is freed.", action: .none))
        }
        if wasSuppressed != settings.rawSuppressedForStorage {
            engine.setRawEnabled(settings.effectiveRaw)
        }
    }
}

#if DEBUG
/// Measures the UI refresh rate with a 120 Hz display link (debug HUD only).
final class FrameRateProbe: NSObject {
    var onRate: ((Double) -> Void)?
    private var link: CADisplayLink?
    private var windowStart: CFTimeInterval = 0
    private var frames = 0

    func start() {
        guard link == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    @objc private func tick(_ link: CADisplayLink) {
        if windowStart == 0 { windowStart = link.timestamp }
        frames += 1
        let elapsed = link.timestamp - windowStart
        if elapsed >= 1 {
            onRate?(Double(frames) / elapsed)
            frames = 0
            windowStart = link.timestamp
        }
    }
}
#endif
