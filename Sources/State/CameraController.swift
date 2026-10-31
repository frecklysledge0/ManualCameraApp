import AVFoundation
import Foundation
import Metal
import Photos
import QuartzCore
import SwiftUI
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
    private var hasStarted = false
    private var expectingLensSwitchHaptic = false

    // Persistence
    private var profile: ShootingProfile
    private var saveWorkItem: DispatchWorkItem?

    // Focus
    private var awaitingFocusLock = false
    private var sawFocusAdjusting = false
    private var focusLockWorkItem: DispatchWorkItem?
    /// Returns the focus frame from `locked` to `idle` after the confirmation has been seen.
    private var focusStateWorkItem: DispatchWorkItem?
    /// AF-S focus priority: the hardware shutter was released before focus locked, so the photo
    /// is taken on lock (or after a short timeout).
    private var shotWaitingForFocus = false
    private var focusPriorityWorkItem: DispatchWorkItem?
    /// `CameraControlSet` on iOS 18+ (stored untyped because of its availability).
    private var cameraControls: AnyObject?
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

    // Medium Format Edition (Slice 3)
    private let shutterSound = ShutterSoundPlayer()
    private var editionRenderer: EditionPreviewRenderer?
    private var editionDeveloper: EditionDeveloper?
    /// Ignores a look-resource load that finishes after the Edition was turned off again.
    private var editionGeneration = 0
    /// At most this many Edition shots wait for their develop before the shutter holds (Slice 3 §6).
    static let maxEditionInFlight = 3

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
        engine.start(lens: settings.lens, format: settings.captureFormat)
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
        view.onLongPress = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.resetFocusPoint() }
        }
        view.onGeometryChange = { [weak self] geometry in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.status.viewfinder = geometry
                self.updateLoupeWindow()
            }
        }
        if settings.isEdition {
            startEditionPipeline(animated: false)
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
        awaitingFocusLock = false
        focusLockWorkItem?.cancel()
        focusStateWorkItem?.cancel()
        status.focusState = .idle
        switch mode {
        case .continuous:
            engine.send(.focus(.continuousAuto(point: nil)))
        case .single:
            beginFocusLock()
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
    /// the loupe / focus-snap region. In P/A/S the tap also meters there. The focus frame then
    /// stays at that point (like an Alpha body's flexible spot) until a long-press re-centres it.
    func focus(atViewPoint point: CGPoint, devicePoint: CGPoint) {
        if settings.activeTile != nil || settings.showFnSheet {
            // A tap on the viewfinder first dismisses the tray (Slice 2 §4).
            settings.activeTile = nil
            settings.showFnSheet = false
            return
        }
        guard let uv = status.viewfinder.normalizedPoint(for: point) else { return }
        focusPointUV = uv
        updateFocusRegion()
        status.focusPointUV = uv
        status.focusTapID += 1
        focus(devicePoint: devicePoint)
    }

    /// Long-press on the viewfinder: the focus point returns to the centre (Sony's "Centre" area).
    func resetFocusPoint() {
        settings.activeTile = nil
        let center = CGPoint(x: 0.5, y: 0.5)
        focusPointUV = center
        updateFocusRegion()
        status.focusPointUV = nil
        status.focusTapID += 1
        // The centre of the frame is the centre in device coordinates too, in every orientation.
        focus(devicePoint: center)
        haptics.play(.detent)
    }

    private func focus(devicePoint: CGPoint) {
        focusStateWorkItem?.cancel()
        switch settings.focusMode {
        case .single:
            beginFocusLock()
            engine.send(.focus(.singleAuto(point: devicePoint)))
        case .continuous:
            status.focusState = .searching
            engine.send(.focus(.continuousAuto(point: devicePoint)))
            // If the lens is already sharp it may never report adjusting: settle anyway.
            scheduleFocusState(.idle, after: 0.8, onlyIf: .searching)
        case .manual:
            status.focusState = .idle
        }
        if settings.program != .manual || settings.exposure.isoAuto {
            engine.send(.exposurePoint(devicePoint))
        }
    }

    private func beginFocusLock() {
        awaitingFocusLock = true
        sawFocusAdjusting = false
        status.focusState = .searching
        scheduleFocusLockFallback()
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
        status.focusState = .locked
        haptics.play(.focusLock)
        scheduleFocusState(.idle, after: 1.5, onlyIf: .locked)
        if shotWaitingForFocus { takeShotWaitingForFocus() }
    }

    // MARK: - Hardware shutter (Camera Control, volume buttons)

    /// Sony-style shutter button: pressing focuses at the focus frame (the centre unless you
    /// tapped elsewhere), holding keeps the confirmation, releasing takes the photo. In AF-S the
    /// photo waits for focus to lock (at most 0.6 s), so a quick click never shoots mid-focus.
    func hardwareShutter(_ phase: HardwareShutterPhase) {
        switch phase {
        case .pressed:
            halfPress()
        case .released:
            if settings.focusMode == .single && awaitingFocusLock {
                shotWaitingForFocus = true
                focusPriorityWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        if self.shotWaitingForFocus { self.takeShotWaitingForFocus() }
                    }
                }
                focusPriorityWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
            } else {
                shutterPressed()
            }
        case .cancelled:
            shotWaitingForFocus = false
            focusPriorityWorkItem?.cancel()
        }
    }

    /// The half-press: AF-S focuses once at the focus frame and confirms in green; AF-C is already
    /// tracking, so the frame just confirms when the lens is settled. Nothing happens in MF.
    /// Also called when a light press of Camera Control opens its controls.
    func halfPress() {
        guard status.canCapture else { return }
        switch settings.focusMode {
        case .single:
            // A click always passes through a light press: keep a focus that is running or has
            // just locked instead of starting again, so the click shoots straight away.
            guard !awaitingFocusLock, status.focusState != .locked else { return }
            let devicePoint = status.focusPointUV.flatMap { previewView?.devicePoint(forVideoUV: $0) } ?? CGPoint(x: 0.5, y: 0.5)
            focusStateWorkItem?.cancel()
            beginFocusLock()
            engine.send(.focus(.singleAuto(point: devicePoint)))
        case .continuous:
            focusStateWorkItem?.cancel()
            if telemetry.isAdjustingFocus {
                status.focusState = .searching
            } else {
                status.focusState = .locked
                haptics.play(.focusLock)
                scheduleFocusState(.idle, after: 1.0, onlyIf: .locked)
            }
        case .manual:
            break
        }
    }

    /// Builds the Camera Control overlay's controls for the current lens: Aperture (every
    /// accepted 1/3 stop, on lenses with a moving iris), Exposure and Focus. Rebuilt only when
    /// the lens's stops change.
    private func updateCameraControls() {
        guard #available(iOS 18.0, *) else { return }
        let apertureStops = settings.capability.hasVariableAperture ? settings.apertureStops : []
        let evStops = settings.evStops
        if let existing = cameraControls as? CameraControlSet,
           existing.apertureStops == apertureStops, existing.evStops == evStops {
            syncCameraControls()
            return
        }
        let set = CameraControlSet(
            apertureStops: apertureStops,
            evStops: evStops,
            onAperture: { [weak self] value in self?.setAperture(value) },
            onExposure: { [weak self] value in self?.setBias(value) },
            onFocus: { [weak self] value in self?.setLensPositionFromCameraControl(value) }
        )
        cameraControls = set
        set.sync(aperture: currentAperture, bias: settings.exposure.bias, lensPosition: currentLensPosition)
        engine.setCameraControls(set.controls) { [weak self] active in
            guard let self else { return }
            MainActor.assumeIsolated { self.cameraControlsChanged(active: active) }
        }
    }

    private var currentAperture: Float {
        settings.isAutomatic(.aperture) && telemetry.liveAperture > 0 ? telemetry.liveAperture : settings.exposure.aperture
    }

    private var currentLensPosition: Float {
        settings.focusMode == .manual ? settings.lensPosition : telemetry.liveLensPosition
    }

    private func syncCameraControls() {
        guard #available(iOS 18.0, *), let set = cameraControls as? CameraControlSet else { return }
        set.sync(aperture: currentAperture, bias: settings.exposure.bias, lensPosition: currentLensPosition)
    }

    /// A light press opened the overlay: show the current values and focus (the half-press).
    private func cameraControlsChanged(active: Bool) {
        guard active else { return }
        syncCameraControls()
        halfPress()
    }

    /// The Focus control drives the lens directly (switching to MF), like turning a focus ring.
    private func setLensPositionFromCameraControl(_ value: Float) {
        if settings.focusMode != .manual { setFocusMode(.manual) }
        let position = ExposureMath.clamp(value, 0, 1)
        settings.lensPosition = position
        engine.send(.focus(.locked(lensPosition: position)))
        scheduleSave()
    }

    private func takeShotWaitingForFocus() {
        shotWaitingForFocus = false
        focusPriorityWorkItem?.cancel()
        shutterPressed()
    }

    private func scheduleFocusState(_ state: FocusFrameState, after delay: TimeInterval, onlyIf current: FocusFrameState) {
        focusStateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.status.focusState == current { self.status.focusState = state }
            }
        }
        focusStateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// AF-C: the frame shows `searching` while the lens moves and briefly confirms when it settles.
    private func continuousFocusChanged(adjusting: Bool) {
        guard settings.focusMode == .continuous else { return }
        if adjusting {
            focusStateWorkItem?.cancel()
            status.focusState = .searching
        } else if status.focusState == .searching {
            status.focusState = .locked
            scheduleFocusState(.idle, after: 0.6, onlyIf: .locked)
        }
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

    func setCaptureFormat(_ format: CaptureFormat) {
        if format.includesRaw && !settings.rawSupported {
            haptics.play(.limit)
            return
        }
        settings.captureFormat = format
        engine.setCaptureFormat(settings.effectiveFormat)
        updateShotsLeft()
        scheduleSave()
    }

    /// Cycles HEIF → RAW → RAW+HEIF (tap on the format badge).
    func cycleCaptureFormat() {
        let all = settings.rawSupported ? CaptureFormat.allCases : [.heif]
        let index = all.firstIndex(of: settings.captureFormat) ?? 0
        setCaptureFormat(all[(index + 1) % all.count])
        haptics.play(.detent)
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

    // MARK: - Medium Format Edition (Slice 3)

    /// One tap in the Fn sheet: the theme cross-dissolves (0.35 s), the live look fades in and the
    /// shutter develops every shot through MF Natural Colour.
    func setEdition(_ on: Bool) {
        guard on != settings.isEdition else { return }
        settings.activeTile = nil
        withAnimation(.easeInOut(duration: 0.35)) {
            settings.theme = on ? .edition : .alpha
        }
        if on {
            startEditionPipeline(animated: true)
        } else {
            stopEditionPipeline()
        }
        haptics.play(.edition)
        scheduleSave()
    }

    func setFraming(_ framing: FramingMode) {
        guard framing != settings.framing else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            settings.framing = framing
        }
        haptics.play(.detent)
        scheduleSave()
    }

    /// 4:3 → 1:1 → XPAN (tap on the framing badge).
    func cycleFraming() {
        let all = FramingMode.allCases
        let index = all.firstIndex(of: settings.framing) ?? 0
        setFraming(all[(index + 1) % all.count])
    }

    func setGrain(_ grain: GrainLevel) {
        settings.grain = grain
        updatePreviewGrain()
        scheduleSave()
    }

    func setShutterSound(_ volume: ShutterSoundVolume) {
        settings.shutterSound = volume
        let player = shutterSound
        if settings.isEdition {
            DispatchQueue.global(qos: .userInitiated).async {
                player.prepare(volume: volume)
            }
        } else {
            player.setVolume(volume)
        }
        scheduleSave()
    }

    func setPreviewGrain(_ enabled: Bool) {
        settings.previewGrain = enabled
        updatePreviewGrain()
        scheduleSave()
    }

    func setShowPerformanceHUD(_ show: Bool) {
        settings.showPerformanceHUD = show
    }

    private func updatePreviewGrain() {
        let level: GrainLevel = settings.previewGrain ? settings.grain : .off
        editionRenderer?.setGrain(level, iso: settings.exposure.iso)
    }

    /// Loads the LUT and grain off the main thread (first time only), then routes video frames
    /// through the look and fades the look layer in.
    private func startEditionPipeline(animated: Bool) {
        guard let previewView else { return }
        let renderer = editionRenderer ?? EditionPreviewRenderer(layer: previewView.lookView.metalLayer)
        editionRenderer = renderer
        renderer.setSourceIsP3(settings.limits.videoIsP3)
        updatePreviewGrain()
        editionGeneration += 1
        let generation = editionGeneration
        let volume = settings.shutterSound
        let player = shutterSound
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ready = LookResources.shared.load()
            player.prepare(volume: volume)
            guard let self else { return }
            runOnMain { self.editionResourcesLoaded(ready: ready, generation: generation, animated: animated) }
        }
    }

    private func editionResourcesLoaded(ready: Bool, generation: Int, animated: Bool) {
        guard generation == editionGeneration, settings.isEdition, let renderer = editionRenderer else { return }
        guard ready else {
            // The look can't run (missing resource or no Metal): stay on the Pro look.
            status.show(Banner(kind: .edition, message: "\(Branding.lookName) couldn't be loaded.", action: .none))
            withAnimation(.easeInOut(duration: 0.35)) { settings.theme = .alpha }
            scheduleSave()
            return
        }
        engine.pipeline.setFrameRenderer(Self.makeFrameRenderer(renderer))
        previewView?.setLookVisible(true, animated: animated)
    }

    private func stopEditionPipeline() {
        editionGeneration += 1
        previewView?.setLookVisible(false)
        // Keep drawing until the fade-out has finished, then stop paying for the look.
        let generation = editionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard generation == self.editionGeneration, !self.settings.isEdition else { return }
                self.engine.pipeline.setFrameRenderer(nil)
            }
        }
        let player = shutterSound
        DispatchQueue.global(qos: .utility).async {
            player.stop()
        }
    }

    nonisolated private static func makeFrameRenderer(_ renderer: EditionPreviewRenderer) -> (MTLCommandBuffer, MTLTexture, MTLTexture, FramePipeline.Config) -> Void {
        return { commandBuffer, luma, chroma, config in
            renderer.render(commandBuffer: commandBuffer, luma: luma, chroma: chroma, quarterTurns: config.quarterTurns, mirrored: config.mirrored)
        }
    }

    // MARK: - Capture

    func shutterPressed() {
        guard status.canCapture else {
            haptics.play(.limit)
            return
        }
        let pressTime = ProcessInfo.processInfo.systemUptime
        guard settings.isEdition else {
            haptics.play(.shutterPress)
            engine.capture(CaptureEngine.CaptureRequest(format: settings.effectiveFormat, pressTime: pressTime))
            return
        }
        // Edition: each shot is developed (~1–2 s); hold the shutter while three are waiting.
        guard status.inFlightCount < Self.maxEditionInFlight else {
            haptics.play(.limit)
            return
        }
        haptics.play(.leafShutter)
        let developer = editionDeveloper ?? EditionDeveloper()
        editionDeveloper = developer
        let options = EditionDeveloper.Options(
            framing: settings.framing,
            grain: settings.grain,
            iso: telemetry.liveISO > 0 ? telemetry.liveISO : settings.exposure.iso
        )
        engine.capture(CaptureEngine.CaptureRequest(
            format: settings.effectiveFormat,
            pressTime: pressTime,
            develop: Self.makeDevelop(developer, options: options),
            onWillBeginCapture: Self.makeSoundTrigger(shutterSound)
        ))
        // An instant thumbnail from the viewfinder; the developed one replaces it when saved.
        engine.pipeline.makeSnapshot(maxDimension: 240, blurred: false) { [weak self] image in
            guard let self, let image else { return }
            let thumbnail = UIImage(cgImage: image)
            runOnMain { self.status.lastThumbnail = thumbnail }
        }
    }

    /// Built outside the main actor: these closures run on the develop and capture queues.
    nonisolated private static func makeDevelop(_ developer: EditionDeveloper, options: EditionDeveloper.Options) -> (CaptureItem) throws -> CaptureItem {
        return { item in try developer.develop(item, options: options) }
    }

    nonisolated private static func makeSoundTrigger(_ player: ShutterSoundPlayer) -> () -> Void {
        return { player.play() }
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
            engine.setCaptureFormat(settings.effectiveFormat)
            editionRenderer?.setSourceIsP3(limits.videoIsP3)
            updateCameraControls()
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
            } else {
                continuousFocusChanged(adjusting: adjusting)
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
            break

        case .inFlight(let count):
            status.inFlightCount = count

        case .captureFinished(let outcome, let thumbnail):
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
            engine.setCaptureFormat(settings.effectiveFormat)
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
