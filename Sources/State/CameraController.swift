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

    // Persistence
    private var profile: ShootingProfile
    private var saveWorkItem: DispatchWorkItem?

    // Focus
    private var awaitingFocusLock = false
    private var sawFocusAdjusting = false
    private var focusLockWorkItem: DispatchWorkItem?
    private var peakDetector = SharpnessPeakDetector()
    private var isPullingFocus = false
    private var loupeCloseWorkItem: DispatchWorkItem?
    /// Last focus point in display uv (loupe centre and sharpness ROI).
    private var focusPointUV = CGPoint(x: 0.5, y: 0.5)
    private var nativeBufferSize = CGSize.zero
    /// Starting in MF: lock at the lens's first reported position instead of an arbitrary one.
    private var pendingManualFocusLock = false

    // Level
    private var levelIndicator = LevelIndicator()

    // Shots left
    private var freeBytes: Int64?
    private static let rawSizeKey = "averageShotBytes.raw"
    private static let heifSizeKey = "averageShotBytes.heif"

    #if DEBUG
    private let frameProbe = FrameRateProbe()
    #endif

    var metalDevice: MTLDevice? { engine.pipeline.metalDevice }

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = CameraSettings()
        telemetry = LiveTelemetry()
        status = CaptureStatus()
        haptics = HapticsEngine()
        engine = CaptureEngine()
        profile = ShootingProfile.load(from: defaults)

        settings.apply(profile)
        settings.lenses = engine.catalog.allLenses
        let restoredLens = engine.catalog.lens(kind: profile.lensKind) ?? engine.catalog.defaultLens
        settings.lens = restoredLens
        settings.lastBackLens = (restoredLens?.isFront ?? true) ? engine.catalog.defaultLens : restoredLens
        haptics.isEnabled = settings.haptics.enabled
        haptics.intensityScale = settings.haptics.intensity

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
        engine.pipeline.onSharpness = { [weak self] value in
            guard let self else { return }
            runOnMain { self.handleSharpness(value) }
        }
        engine.pipeline.onBufferSize = { [weak self] size in
            guard let self else { return }
            runOnMain { self.nativeBufferSize = size }
        }
        motion.onReading = { [weak self] reading in
            guard let self else { return }
            runOnMain { self.handleMotion(reading) }
        }
        observeSystem()
        applyOverlayConfig()
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
            if hasStarted { refreshAuthorization() }
            return
        }
        engine.resume()
        updateMotionSampling()
        checkStorage()
        checkPhotosAccess(request: false)
    }

    func sceneEnteredBackground() {
        engine.suspend()
        motion.stop()
        saveProfileNow()
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
        updateMotionSampling()
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
                message: "Photos access is off. Shots are saved to Files › \(Branding.appName).",
                action: .openSettings
            ))
        }
    }

    // MARK: - Preview

    func attachPreview(_ view: PreviewView) {
        previewView = view
        engine.attach(previewLayer: view.videoPreviewLayer)
        engine.pipeline.attachOverlay(view.overlayView.metalLayer)
        engine.pipeline.attachLoupe(view.loupeView.metalLayer)
        view.onTap = { [weak self] point, devicePoint in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.focus(atViewPoint: point, devicePoint: devicePoint)
            }
        }
        view.onLoupeTap = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.toggleLoupeZoom() }
        }
        view.onGeometryChange = { [weak self] geometry in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.status.viewfinder = geometry
                self.updateLoupeWindow()
            }
        }
    }

    // MARK: - Fn bar and tray

    func tapTile(_ tile: FnTile) {
        settings.showFnSheet = false
        settings.activeTile = settings.activeTile == tile ? nil : tile
    }

    func dismissTray() {
        settings.activeTile = nil
    }

    func toggleFnSheet() {
        settings.activeTile = nil
        settings.showFnSheet.toggle()
    }

    /// Long-press on a tile returns that parameter to AUTO (Slice 2 §4).
    func resetTileToAuto(_ tile: FnTile) {
        switch tile {
        case .mode:
            setProgram(.program)
        case .aperture:
            switch settings.program {
            case .aperturePriority: setProgram(.program)
            case .manual where settings.availablePrograms.contains(.shutterPriority): setProgram(.shutterPriority)
            default: haptics.play(.limit); return
            }
        case .shutter:
            switch settings.program {
            case .shutterPriority: setProgram(.program)
            case .manual:
                setProgram(settings.availablePrograms.contains(.aperturePriority) ? .aperturePriority : .program)
            default: haptics.play(.limit); return
            }
        case .iso:
            guard settings.program == .manual, !settings.exposure.isoAuto else {
                haptics.play(.limit)
                return
            }
            settings.exposure.isoAuto = true
            applyExposure()
        case .ev:
            setBias(0)
        case .whiteBalance:
            setWhiteBalance(.auto)
        case .focus:
            setFocusMode(.continuous)
        }
        haptics.play(.modeChange)
    }

    // MARK: - Exposure (Slice 2 §6)

    private var liveExposure: LiveExposure {
        LiveExposure(iso: telemetry.liveISO, shutter: telemetry.liveShutter, aperture: telemetry.liveAperture)
    }

    func setProgram(_ program: ExposureProgram) {
        guard program != settings.program else { return }
        guard settings.availablePrograms.contains(program) else {
            haptics.play(.limit)
            return
        }
        profile.setValues(settings.exposure, for: settings.program)
        let stored = profile.values(for: program)
        let values = ExposureRules.transition(from: settings.program, to: program, values: stored, live: liveExposure)
        settings.program = program
        settings.exposure = values
        applyExposure()
        haptics.play(.modeChange)
        scheduleSave()
    }

    /// Sends the current mode's plan to the engine (coalesced on the session queue).
    private func applyExposure() {
        let plan = ExposureRules.plan(
            for: settings.program,
            values: settings.exposure,
            live: liveExposure,
            capability: settings.capability
        )
        engine.apply(plan)
        scheduleSave()
    }

    /// Moving the shutter dial in P or A takes manual control of the shutter (P→S, A→M).
    func setShutter(_ seconds: Double) {
        switch settings.program {
        case .program: setProgram(.shutterPriority)
        case .aperturePriority: setProgram(.manual)
        case .shutterPriority, .manual: break
        }
        settings.exposure.shutter = settings.limits.clampDuration(seconds)
        applyExposure()
    }

    /// Moving the ISO dial outside M switches to M at the current values.
    func setISO(_ iso: Float) {
        if settings.program != .manual { setProgram(.manual) }
        settings.exposure.isoAuto = false
        settings.exposure.iso = settings.limits.clampISO(iso)
        applyExposure()
    }

    /// Moving the aperture dial in P or S takes manual control of the iris (P→A, S→M).
    func setAperture(_ aperture: Float) {
        guard settings.capability.hasVariableAperture else {
            haptics.play(.limit)
            return
        }
        switch settings.program {
        case .program: setProgram(.aperturePriority)
        case .shutterPriority: setProgram(.manual)
        case .aperturePriority, .manual: break
        }
        settings.exposure.aperture = settings.limits.clampAperture(aperture)
        applyExposure()
    }

    func setBias(_ bias: Float) {
        guard !settings.evIsMeteredManual else { return }
        settings.exposure.bias = settings.limits.clampBias(bias)
        applyExposure()
    }

    func toggleAutoISO() {
        guard settings.program == .manual else { return }
        settings.exposure.isoAuto.toggle()
        applyExposure()
        haptics.play(.modeChange)
    }

    // MARK: - White balance

    func setWhiteBalance(_ stop: WhiteBalanceStop) {
        settings.whiteBalance = stop
        sendWhiteBalance()
    }

    func setTint(_ tint: Float) {
        settings.tint = ExposureMath.clamp(tint, -150, 150)
        if settings.whiteBalance == .auto, telemetry.liveTemperature > 0 {
            // Tint needs a locked temperature: start from the current auto value.
            settings.whiteBalance = .kelvin(Int((telemetry.liveTemperature / 100).rounded()) * 100)
        }
        sendWhiteBalance()
    }

    private func sendWhiteBalance() {
        if let kelvin = settings.whiteBalance.kelvinValue {
            engine.send(.whiteBalance(.locked(temperature: kelvin, tint: settings.tint)))
        } else {
            engine.send(.whiteBalance(.auto))
        }
        scheduleSave()
    }

    // MARK: - Focus (Slice 2 §8)

    func setFocusMode(_ mode: FocusMode) {
        guard mode != settings.focusMode else { return }
        settings.focusMode = mode
        switch mode {
        case .continuous:
            engine.send(.focus(.continuousAuto(point: nil)))
        case .single:
            engine.send(.focus(.singleAuto(point: nil)))
        case .manual:
            let position = telemetry.liveLensPosition > 0 ? telemetry.liveLensPosition : settings.lensPosition
            settings.lensPosition = position
            engine.send(.focus(.locked(lensPosition: position)))
        }
        applyOverlayConfig()
        scheduleSave()
    }

    /// Tap on the viewfinder: AF-S focuses once and confirms, AF-C tracks the point, MF only moves
    /// the loupe / focus-snap region. In P/A/S the tap also meters there.
    func focus(atViewPoint point: CGPoint, devicePoint: CGPoint) {
        if settings.activeTile != nil || settings.showFnSheet {
            // A tap on the viewfinder first dismisses the tray (Slice 2 §4).
            settings.activeTile = nil
            settings.showFnSheet = false
            return
        }
        if let uv = status.viewfinder.normalizedPoint(for: point) {
            focusPointUV = uv
            updateFocusRegion()
        }
        switch settings.focusMode {
        case .single:
            awaitingFocusLock = true
            sawFocusAdjusting = false
            engine.send(.focus(.singleAuto(point: devicePoint)))
            scheduleFocusLockFallback()
        case .continuous:
            engine.send(.focus(.continuousAuto(point: devicePoint)))
        case .manual:
            break
        }
        if settings.program != .manual || settings.exposure.isoAuto {
            engine.send(.exposurePoint(devicePoint))
        }
        focusTapCounter += 1
        status.focusIndicator = FocusIndicator(point: status.viewfinder.clampedToVideo(point), id: focusTapCounter)
        let tapID = focusTapCounter
        let hold: TimeInterval = settings.focusMode == .single ? 2.0 : 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.status.focusIndicator?.id == tapID {
                    self.status.focusIndicator = nil
                }
            }
        }
    }

    /// If the lens was already sharp, `isAdjustingFocus` may never go true: confirm anyway.
    private func scheduleFocusLockFallback() {
        focusLockWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.awaitingFocusLock, !self.sawFocusAdjusting { self.confirmFocusLock() }
            }
        }
        focusLockWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func confirmFocusLock() {
        awaitingFocusLock = false
        focusLockWorkItem?.cancel()
        status.focusIndicator?.locked = true
        haptics.play(.focusLock)
    }

    func mfWheelBegan() {
        if settings.focusMode != .manual { setFocusMode(.manual) }
        isPullingFocus = true
        peakDetector.reset()
        loupeCloseWorkItem?.cancel()
        updateFocusRegion()
        engine.pipeline.updateConfig {
            $0.sharpnessEnabled = true
            $0.loupeEnabled = true
        }
        status.isLoupeVisible = true
        previewView?.setLoupeVisible(true)
    }

    /// - Parameters:
    ///   - translation: Points moved since the last call (positive = towards infinity).
    ///   - speed: Finger speed in points per second.
    func mfWheelMoved(by translation: Double, speed: Double) {
        let old = settings.lensPosition
        let new = FocusMath.position(after: translation, speed: speed, from: old)
        guard new != old else { return }
        settings.lensPosition = new
        engine.send(.focus(.locked(lensPosition: new)))
        if FocusMath.detentIndex(for: old) != FocusMath.detentIndex(for: new) {
            haptics.play(new <= 0 || new >= 1 ? .limit : .focusTick)
        }
    }

    func mfWheelEnded() {
        isPullingFocus = false
        scheduleSave()
        scheduleLoupeClose(after: 0.6)
    }

    private func scheduleLoupeClose(after delay: TimeInterval) {
        loupeCloseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard !self.isPullingFocus else { return }
                self.engine.pipeline.updateConfig {
                    $0.sharpnessEnabled = false
                    $0.loupeEnabled = false
                }
                self.status.isLoupeVisible = false
                self.previewView?.setLoupeVisible(false)
            }
        }
        loupeCloseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 4× ⇄ 8× (8× only when the video frame has real pixels for it, §8).
    func toggleLoupeZoom() {
        let next = settings.loupeZoom == 4 && canUseEightTimesLoupe ? 8 : 4
        settings.loupeZoom = next
        updateLoupeWindow()
        haptics.play(.detent)
        if status.isLoupeVisible { scheduleLoupeClose(after: 2.0) }
    }

    var canUseEightTimesLoupe: Bool {
        max(nativeBufferSize.width, nativeBufferSize.height) > 1920
    }

    private func updateLoupeWindow() {
        guard let previewView else { return }
        let window = previewView.loupeWindow(zoom: settings.loupeZoom)
        let nearest = settings.loupeZoom >= 8
        engine.pipeline.updateConfig {
            $0.loupeWindow = window
            $0.loupeNearest = nearest
        }
    }

    /// The loupe centre and the focus-snap region follow the last focus point.
    private func updateFocusRegion() {
        let size: CGFloat = 0.2
        let roi = CGRect(
            x: ExposureMath.clamp(focusPointUV.x - size / 2, 0, 1 - size),
            y: ExposureMath.clamp(focusPointUV.y - size / 2, 0, 1 - size),
            width: size,
            height: size
        )
        let center = focusPointUV
        engine.pipeline.updateConfig {
            $0.sharpnessROI = roi
            $0.loupeCenter = center
        }
        updateLoupeWindow()
    }

    private func handleSharpness(_ value: Double) {
        guard isPullingFocus else { return }
        if peakDetector.add(value) {
            haptics.play(.focusSnap)
            engine.pipeline.flashPeaking()
        }
    }

    // MARK: - Lenses

    func switchLens(_ lens: LensOption) {
        guard lens != settings.lens, !status.isSwitchingLens else { return }
        status.isSwitchingLens = true
        expectingLensSwitchHaptic = true
        if !lens.isFront { settings.lastBackLens = lens }
        engine.switchLens(to: lens)
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

    // MARK: - Overlays, RAW, haptics (Fn sheet)

    func updateOverlays(_ change: (inout OverlaySettings) -> Void) {
        change(&settings.overlays)
        applyOverlayConfig()
        updateMotionSampling()
        scheduleSave()
    }

    private func applyOverlayConfig() {
        let overlays = settings.overlays
        let peaking = settings.peakingActive
        engine.pipeline.updateConfig {
            $0.peakingEnabled = peaking
            $0.peakingColor = overlays.peakingColor.rgba
            $0.peakingThreshold = overlays.peakingLevel.threshold
            $0.zebrasEnabled = overlays.zebrasEnabled
            $0.zebraThreshold = overlays.zebraThreshold.luma
        }
    }

    func toggleHistogramExpanded() {
        settings.histogramExpanded.toggle()
    }

    func toggleRaw() {
        guard settings.rawSupported else {
            haptics.play(.limit)
            return
        }
        settings.rawEnabled.toggle()
        engine.setRawEnabled(settings.effectiveRaw)
        updateShotsLeft()
        scheduleSave()
    }

    func setHapticsEnabled(_ enabled: Bool) {
        settings.haptics.enabled = enabled
        haptics.isEnabled = enabled
        scheduleSave()
    }

    func setHapticIntensity(_ intensity: Float) {
        settings.haptics.intensity = ExposureMath.clamp(intensity, 0.5, 1.0)
        haptics.intensityScale = settings.haptics.intensity
        scheduleSave()
    }

    // MARK: - Capture

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
            if !settings.availablePrograms.contains(settings.program) {
                // A without a moving iris on this lens: fall back to P.
                settings.program = .program
            }
            settings.exposure.iso = limits.clampISO(settings.exposure.iso)
            settings.exposure.shutter = limits.clampDuration(settings.exposure.shutter)
            settings.exposure.bias = limits.clampBias(settings.exposure.bias)
            if limits.exposure.hasVariableAperture {
                settings.exposure.aperture = limits.clampAperture(settings.exposure.aperture)
            }
            applyExposure()
            sendWhiteBalance()
            if settings.focusMode == .single {
                engine.send(.focus(.singleAuto(point: nil)))
            } else if settings.focusMode == .manual && telemetry.liveLensPosition <= 0 {
                pendingManualFocusLock = true
            }
            engine.setRawEnabled(settings.effectiveRaw)
            previewView?.refreshGeometry()
            updateShotsLeft()
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
            if pendingManualFocusLock, values.lensPosition > 0 {
                pendingManualFocusLock = false
                if settings.focusMode == .manual {
                    settings.lensPosition = values.lensPosition
                    engine.send(.focus(.locked(lensPosition: values.lensPosition)))
                }
            }

        case .focusAdjusting(let adjusting):
            telemetry.isAdjustingFocus = adjusting
            if awaitingFocusLock {
                if adjusting {
                    sawFocusAdjusting = true
                } else if sawFocusAdjusting {
                    confirmFocusLock()
                }
            }

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
            case .saved(let destination, _, let bytes):
                if let thumbnail { status.lastThumbnail = thumbnail }
                haptics.play(.saved)
                recordShotSize(bytes, raw: settings.effectiveRaw)
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
                if settings.program == .program { settings.exposure.bias = bias }
            case .custom(let iso, let duration):
                if settings.program == .manual && !settings.exposure.isoAuto {
                    settings.exposure.iso = iso
                    settings.exposure.shutter = duration
                } else if settings.program == .shutterPriority || settings.program == .manual {
                    settings.exposure.shutter = duration
                }
            case .priority(let aperture, let duration, let iso, _):
                if let aperture { settings.exposure.aperture = aperture }
                if let duration, settings.program == .shutterPriority || settings.program == .manual {
                    settings.exposure.shutter = duration
                }
                if let iso, settings.program == .manual { settings.exposure.iso = iso }
            }
        }
        if let whiteBalance = applied.whiteBalance, !whiteBalance.isAuto {
            settings.tint = whiteBalance.tint
        }
        if let focus = applied.focus, case .locked(let position) = focus {
            settings.lensPosition = position
        }
    }

    // MARK: - Motion and level (Slice 2 §9)

    private func handleMotion(_ reading: MotionReading) {
        telemetry.rollDegrees = reading.rollDegrees
        telemetry.pitchDegrees = reading.pitchDegrees
        let becameLevel = levelIndicator.update(rollDegrees: reading.rollDegrees, pitchDegrees: reading.pitchDegrees)
        telemetry.rollIsLevel = levelIndicator.rollIsLevel
        telemetry.pitchIsLevel = levelIndicator.pitchIsLevel
        if becameLevel, settings.overlays.levelEnabled {
            haptics.play(.level)
        }
    }

    private func updateMotionSampling() {
        let needed = settings.overlays.levelEnabled || settings.overlays.levelLine
        if needed && status.authorization == .authorized {
            motion.start()
        } else {
            motion.stop()
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

    // MARK: - Storage and shots left

    private func checkStorage() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let url = URL(fileURLWithPath: NSHomeDirectory())
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let bytes = values?.volumeAvailableCapacityForImportantUsage
            guard let self else { return }
            runOnMain { self.applyStorage(bytes) }
        }
    }

    private func applyStorage(_ bytes: Int64?) {
        freeBytes = bytes
        let level = StoragePolicy.level(forAvailableBytes: bytes)
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
        updateShotsLeft()
    }

    /// Running average of real shot sizes per format (starts from typical 48 MP sizes).
    private func recordShotSize(_ bytes: Int, raw: Bool) {
        guard bytes > 0 else { return }
        let key = raw ? Self.rawSizeKey : Self.heifSizeKey
        let previous = defaults.double(forKey: key)
        let average = previous > 0 ? previous * 0.7 + Double(bytes) * 0.3 : Double(bytes)
        defaults.set(average, forKey: key)
        updateShotsLeft()
    }

    private func updateShotsLeft() {
        guard let freeBytes else {
            telemetry.shotsLeft = nil
            return
        }
        let raw = settings.effectiveRaw
        let stored = defaults.double(forKey: raw ? Self.rawSizeKey : Self.heifSizeKey)
        let average = stored > 0 ? stored : (raw ? 80_000_000 : 8_000_000)
        telemetry.shotsLeft = max(0, Int(Double(freeBytes) / average))
    }

    // MARK: - Persistence (Slice 2 §11)

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.saveProfileNow() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func saveProfileNow() {
        saveWorkItem?.cancel()
        settings.store(into: &profile)
        profile.save(to: defaults)
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
