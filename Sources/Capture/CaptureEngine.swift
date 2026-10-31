import AVFoundation
import Foundation
import os
import UIKit

/// Owns the `AVCaptureSession` and everything attached to it (§5). All mutable state is confined
/// to `sessionQueue`; results reach the UI only through `onEvent`, which is always called on the
/// main thread. The engine never imports SwiftUI or touches the state objects.
final class CaptureEngine: NSObject, @unchecked Sendable {

    enum Event {
        case noCamera
        case configured(lens: LensOption, limits: DeviceLimits, rawSupported: Bool)
        case applied(AppliedDeviceState)
        case live(LiveDeviceValues)
        case readiness(Bool)
        case running(Bool)
        case interrupted(String)
        case interruptionEnded
        case sessionFailed(String)
        case snapshot(CGImage?)
        case firstFrameAfterSwitch
        case willCapture(latencyMS: Double)
        case captureStarted
        case captureFinished(CaptureOutcome, thumbnail: UIImage?)
        case previewAngle(CGFloat)
        case feedRate(Double)
        case pendingSaves(Int)
        case focusAdjusting(Bool)
    }

    /// Called on the main thread.
    var onEvent: ((Event) -> Void)?

    let session = AVCaptureSession()
    let pipeline: FramePipeline
    let catalog: DeviceCatalog

    private let sessionQueue = DispatchQueue(label: "camera.sessionQueue", qos: .userInitiated)
    private let logger = Logger(subsystem: "ManualCameraApp", category: "CaptureEngine")

    // sessionQueue-confined state
    private var photoOutput = AVCapturePhotoOutput()
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private var readinessCoordinator: AVCapturePhotoOutputReadinessCoordinator?
    private var inputs: [String: AVCaptureDeviceInput] = [:]
    private var activeLens: LensOption?
    private var activeInput: AVCaptureDeviceInput?
    private var activeCameraDevice: AVCameraDevice?
    private lazy var deviceController: DeviceController = {
        let controller = DeviceController(scheduler: QueueScheduler(queue: sessionQueue))
        controller.onApplied = { [weak self] applied in self?.post(.applied(applied)) }
        controller.onLockFailure = { [weak self] error in
            self?.logger.error("Device lock failed: \(error.localizedDescription, privacy: .public)")
        }
        return controller
    }()
    private let rotation = RotationController()
    private let fileStore: CaptureFileStore
    private let saver: PhotoLibrarySaver
    private var delegates: [Int64: PhotoCaptureDelegate] = [:]
    private var isConfigured = false
    private var wantsRunning = false
    private var didRetryAfterError = false
    private var rawRequested = true
    private var frameRateCap: Double = 60
    private var liveTimer: DispatchSourceTimer?
    private var lastLive: LiveDeviceValues?
    private var notificationTokens: [NSObjectProtocol] = []
    private var focusObservation: NSKeyValueObservation?
    // Auto-ISO loop (Slice 2 §6)
    private var autoISOLoop: AutoISOLoop?
    private var loopISO: Float = 0

    // Written on the main thread, read on the session queue.
    private let previewLock = NSLock()
    private weak var storedPreviewLayer: AVCaptureVideoPreviewLayer?

    private var previewLayer: AVCaptureVideoPreviewLayer? {
        get {
            previewLock.lock()
            defer { previewLock.unlock() }
            return storedPreviewLayer
        }
        set {
            previewLock.lock()
            storedPreviewLayer = newValue
            previewLock.unlock()
        }
    }

    /// Optional development step for each capture (Slice 3 Edition). Set on the main thread.
    var developProvider: (() -> ((CaptureItem) throws -> CaptureItem)?)?

    init(catalog: DeviceCatalog = DeviceCatalog(), pipeline: FramePipeline = FramePipeline(), fileStore: CaptureFileStore = CaptureFileStore()) {
        self.catalog = catalog
        self.pipeline = pipeline
        self.fileStore = fileStore
        self.saver = PhotoLibrarySaver(store: fileStore)
        super.init()

        pipeline.onFirstFrame = { [weak self] in self?.post(.firstFrameAfterSwitch) }
        pipeline.onFeedRate = { [weak self] rate in self?.post(.feedRate(rate)) }
        rotation.onPreviewAngleChange = { [weak self] angle in self?.post(.previewAngle(angle)) }
        observeSessionNotifications()
    }

    deinit {
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Main-thread helpers

    private func post(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    /// Connects the preview layer. Call on the main thread.
    func attach(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        previewLayer.session = session
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeInput?.device else { return }
            self.rotation.bind(device: device, previewLayer: previewLayer)
        }
    }

    /// Applies the preview angle to the preview connection. Call on the main thread.
    func applyPreviewAngle(_ angle: CGFloat) {
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        let turns = RotationMath.quarterTurns(forRotationAngle: Double(angle))
        let mirrored = previewLayer?.connection?.isVideoMirrored ?? false
        pipeline.updateConfig {
            $0.quarterTurns = turns
            $0.mirrored = mirrored
        }
    }

    // MARK: - Lifecycle

    func start(lens: LensOption?, rawEnabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.rawRequested = rawEnabled
            self.wantsRunning = true
            if !self.isConfigured {
                self.configureSession(initialLens: lens ?? self.catalog.defaultLens)
            }
            self.startRunningIfNeeded()
        }
        retryPendingSaves(cleanOrphans: true)
    }

    func resume() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.startRunningIfNeeded()
        }
    }

    func suspend() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            self.stopLiveTimer()
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.post(.running(false))
        }
    }

    func retrySession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.didRetryAfterError = false
            self.wantsRunning = true
            if !self.isConfigured {
                self.configureSession(initialLens: self.activeLens ?? self.catalog.defaultLens)
            }
            self.startRunningIfNeeded()
        }
    }

    private func startRunningIfNeeded() {
        guard isConfigured, wantsRunning, !session.isRunning else {
            if session.isRunning { post(.running(true)) }
            return
        }
        session.startRunning()
        let running = session.isRunning
        post(.running(running))
        if running {
            startLiveTimer()
        }
    }

    // MARK: - Session configuration

    private func configureSession(initialLens: LensOption?) {
        guard let lens = initialLens, let device = catalog.device(for: lens) else {
            post(.noCamera)
            return
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo
        }

        // Create every lens's input up front so switching never waits for one (F11).
        for option in catalog.allLenses where inputs[option.id] == nil {
            if let candidate = catalog.device(for: option) {
                do {
                    inputs[option.id] = try AVCaptureDeviceInput(device: candidate)
                } catch {
                    logger.error("Input for \(option.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard let input = inputs[lens.id], session.canAddInput(input) else {
            session.commitConfiguration()
            post(.noCamera)
            return
        }
        session.addInput(input)
        activeInput = input
        activeLens = lens

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            let wanted = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if videoDataOutput.availableVideoPixelFormatTypes.contains(wanted) {
                videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: wanted]
            }
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(pipeline, queue: pipeline.videoQueue)
        }
        configurePhotoOutput(for: device)
        configureVideoConnection(for: lens)
        session.commitConfiguration()

        configureFrameRate(for: device)
        let readiness = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
        readiness.delegate = self
        readinessCoordinator = readiness

        bindActiveDevice(device, lens: lens, reapply: false)
        isConfigured = true
    }

    /// Photo output setup for the active format (§7). Must run inside begin/commitConfiguration.
    private func configurePhotoOutput(for device: AVCaptureDevice) {
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
        if let largest = dimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        photoOutput.maxPhotoQualityPrioritization = .quality
        if photoOutput.isZeroShutterLagSupported {
            photoOutput.isZeroShutterLagEnabled = true
        }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true
        }
        if photoOutput.isFastCapturePrioritizationSupported {
            photoOutput.isFastCapturePrioritizationEnabled = true
        }
        logger.info("""
        Photo output: \(device.localizedName, privacy: .public) max \(self.photoOutput.maxPhotoDimensions.width)x\(self.photoOutput.maxPhotoDimensions.height) \
        proRAW=\(self.photoOutput.isAppleProRAWEnabled) zsl=\(self.photoOutput.isZeroShutterLagEnabled) \
        responsive=\(self.photoOutput.isResponsiveCaptureEnabled) fast=\(self.photoOutput.isFastCapturePrioritizationEnabled)
        """)
    }

    /// The video data output stays unrotated (the shaders rotate); mirroring is off so the
    /// shaders' mirror flag is the only mirror in the overlay path.
    private func configureVideoConnection(for lens: LensOption) {
        guard let connection = videoDataOutput.connection(with: .video) else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// Runs the feed at the highest frame rate of the active format, capped at `frameRateCap` (§10).
    /// If the higher rate disables ProRAW, the format's default rate is restored.
    private func configureFrameRate(for device: AVCaptureDevice) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return }
        let target = min(range.maxFrameRate, frameRateCap)
        let hadProRAW = photoOutput.isAppleProRAWSupported
        do {
            try device.lockForConfiguration()
            if target >= range.maxFrameRate {
                device.activeVideoMinFrameDuration = range.minFrameDuration
            } else {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, target.rounded())))
            }
            device.unlockForConfiguration()
        } catch {
            logger.error("Frame rate lock failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        if hadProRAW && !photoOutput.isAppleProRAWSupported {
            if (try? device.lockForConfiguration()) != nil {
                device.activeVideoMinFrameDuration = .invalid
                device.unlockForConfiguration()
            }
            logger.info("High frame rate disables ProRAW on this format; using the default rate.")
        }
        let duration = device.activeVideoMinFrameDuration.seconds
        let rate = duration.isFinite && duration > 0 ? 1 / duration : 30
        deviceController.minimumInterval = 1 / max(rate, 1)
        pipeline.updateConfig { $0.feedFrameRate = rate }
    }

    private func bindActiveDevice(_ device: AVCaptureDevice, lens: LensOption, reapply: Bool) {
        let wrapper = AVCameraDevice(device: device)
        activeCameraDevice = wrapper
        focusObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self] observed, _ in
            self?.post(.focusAdjusting(observed.isAdjustingFocus))
        }
        deviceController.bind(wrapper, reapply: reapply)
        rotation.bind(device: device, previewLayer: previewLayer)
        preparePhotoSettings()
        lastLive = nil
        post(.configured(lens: lens, limits: wrapper.limits, rawSupported: rawPixelFormat() != nil))
    }

    // MARK: - Device commands

    func send(_ command: DeviceCommand) {
        sessionQueue.async { [weak self] in
            self?.deviceController.submit(command)
        }
    }

    /// Enters manual exposure at the camera's current auto values so the image does not jump (F8).
    func enterManualExposure() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.activeCameraDevice else { return }
            self.autoISOLoop = nil
            self.deviceController.submit(.exposure(.custom(iso: device.currentISO, duration: device.currentDuration)))
            self.deviceController.flushNow()
        }
    }

    /// Applies an exposure plan (Slice 2 §6): the command, plus the auto-ISO loop when S or
    /// Auto ISO has to be emulated.
    func apply(_ plan: ExposurePlan) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let loop = plan.loop {
                if self.autoISOLoop == nil {
                    // Seed the loop with the ISO the camera is using right now.
                    if case .custom(let iso, _) = plan.command {
                        self.loopISO = iso
                    } else {
                        self.loopISO = self.activeCameraDevice?.currentISO ?? 100
                    }
                }
                self.autoISOLoop = loop
                self.deviceController.submit(.exposure(.custom(iso: self.loopISO, duration: loop.duration)))
            } else {
                self.autoISOLoop = nil
                self.deviceController.submit(plan.command)
            }
        }
    }

    /// Returns everything to auto and forgets the remembered manual values.
    func resetToAuto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.autoISOLoop = nil
            self.deviceController.resetRemembered()
            self.deviceController.submit(.exposure(.auto(bias: 0)))
            self.deviceController.submit(.whiteBalance(.auto))
            self.deviceController.submit(.focus(.continuousAuto(point: nil)))
        }
    }

    // MARK: - Lens switching (§8)

    func switchLens(to lens: LensOption) {
        sessionQueue.async { [weak self] in
            self?.performLensSwitch(to: lens)
        }
    }

    private func performLensSwitch(to lens: LensOption) {
        guard isConfigured, lens != activeLens, let device = catalog.device(for: lens) else { return }
        let input: AVCaptureDeviceInput
        if let cached = inputs[lens.id] {
            input = cached
        } else {
            do {
                input = try AVCaptureDeviceInput(device: device)
                inputs[lens.id] = input
            } catch {
                logger.error("Input creation failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // 1–2. Show a blurred copy of the last frame before the preview goes dark.
        if session.isRunning {
            let shown = DispatchSemaphore(value: 0)
            pipeline.makeSnapshot { [weak self] image in
                guard let self else {
                    shown.signal()
                    return
                }
                DispatchQueue.main.async {
                    self.onEvent?(.snapshot(image))
                    shown.signal()
                }
            }
            _ = shown.wait(timeout: .now() + 0.12)
        }

        // 3. Swap the input.
        session.beginConfiguration()
        let previousInput = activeInput
        if let previousInput {
            session.removeInput(previousInput)
        }
        guard session.canAddInput(input) else {
            if let previousInput, session.canAddInput(previousInput) {
                session.addInput(previousInput)
            }
            session.commitConfiguration()
            post(.firstFrameAfterSwitch)
            return
        }
        session.addInput(input)
        activeInput = input
        activeLens = lens
        configurePhotoOutput(for: device)
        configureVideoConnection(for: lens)
        session.commitConfiguration()
        configureFrameRate(for: device)

        // 4. Re-apply the user's settings, clamped to the new lens (5 happens on the first frame).
        pipeline.expectFirstFrame(fromDeviceID: device.uniqueID)
        bindActiveDevice(device, lens: lens, reapply: true)
        if !session.isRunning {
            post(.firstFrameAfterSwitch)
        }
    }

    // MARK: - RAW and thermal

    func setRawEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, self.rawRequested != enabled else { return }
            self.rawRequested = enabled
            self.preparePhotoSettings()
        }
    }

    /// Thermal handling (§10): histogram and peaking slow down at `.serious`; the feed drops to
    /// 30 fps at `.critical`.
    func setThermalLevel(_ level: ThermalLevel) {
        pipeline.updateConfig { $0.thermal = level }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let cap: Double = level >= .critical ? 30 : 60
            guard cap != self.frameRateCap else { return }
            self.frameRateCap = cap
            if let device = self.activeInput?.device {
                self.configureFrameRate(for: device)
            }
        }
    }

    // MARK: - Photo settings (§7)

    private func rawPixelFormat() -> OSType? {
        let formats = photoOutput.availableRawPhotoPixelFormatTypes
        if let proRAW = formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return proRAW
        }
        return formats.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
    }

    private var processedCodec: AVVideoCodecType {
        photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
    }

    private var processedTypeIdentifier: String {
        processedCodec == .hevc ? "public.heic" : "public.jpeg"
    }

    private func makePhotoSettings(raw: Bool, customExposure: Bool) -> (settings: AVCapturePhotoSettings, isRaw: Bool) {
        let codec = processedCodec
        let settings: AVCapturePhotoSettings
        var isRaw = false
        if raw, let rawFormat = rawPixelFormat() {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat, processedFormat: [AVVideoCodecKey: codec])
            isRaw = true
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        }
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions

        // F6: locked manual exposure is only honoured with `.speed`.
        var priority: AVCapturePhotoOutput.QualityPrioritization = customExposure ? .speed : .balanced
        if isRaw, AVCapturePhotoOutput.isBayerRAWPixelFormat(settings.rawPhotoPixelFormatType) {
            // Bayer RAW is a single unfused frame.
            priority = .speed
        }
        if priority.rawValue > photoOutput.maxPhotoQualityPrioritization.rawValue {
            priority = photoOutput.maxPhotoQualityPrioritization
        }
        settings.photoQualityPrioritization = priority
        return (settings, isRaw)
    }

    private func preparePhotoSettings() {
        guard session.outputs.contains(photoOutput) else { return }
        let custom = deviceController.exposureState?.isLocked ?? false
        var templates = [makePhotoSettings(raw: false, customExposure: custom).settings]
        if rawPixelFormat() != nil {
            templates.insert(makePhotoSettings(raw: true, customExposure: custom).settings, at: 0)
        }
        photoOutput.setPreparedPhotoSettingsArray(templates) { [weak self] prepared, error in
            if let error {
                self?.logger.error("Prepare failed: \(error.localizedDescription, privacy: .public)")
            } else if !prepared {
                self?.logger.info("Photo settings not prepared")
            }
        }
    }

    // MARK: - Capture (§6.3)

    /// - Parameters:
    ///   - raw: Whether to include the DNG (already combined with storage and support checks).
    ///   - pressTime: `systemUptime` at the shutter press, for latency logging.
    func capture(raw: Bool, pressTime: TimeInterval) {
        sessionQueue.async { [weak self] in
            self?.performCapture(raw: raw, pressTime: pressTime)
        }
    }

    private func performCapture(raw: Bool, pressTime: TimeInterval) {
        guard isConfigured, session.isRunning, session.outputs.contains(photoOutput) else { return }
        // Apply any slider movement still waiting in the coalescer before the exposure starts.
        deviceController.flushNow()

        let custom = deviceController.exposureState?.isLocked ?? false
        let (settings, isRaw) = makePhotoSettings(raw: raw, customExposure: custom)

        if let connection = photoOutput.connection(with: .video) {
            let angle = rotation.captureAngle
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }

        let processor = PhotoCaptureProcessor(
            uniqueID: settings.uniqueID,
            expectsRaw: isRaw,
            processedType: processedTypeIdentifier,
            pressTime: pressTime,
            saver: saver,
            store: fileStore
        )
        processor.develop = developProvider?()
        processor.onWillCapture = { [weak self] in
            let latency = (ProcessInfo.processInfo.systemUptime - pressTime) * 1000
            self?.logger.info("Press→willCapture \(latency, format: .fixed(precision: 1)) ms (raw=\(isRaw))")
            self?.post(.willCapture(latencyMS: latency))
        }
        processor.onFinish = { [weak self] finished, outcome in
            guard let self else { return }
            var thumbnail: UIImage?
            if case .saved(_, let source, _) = outcome, let source {
                thumbnail = ThumbnailMaker.thumbnail(from: source)
            }
            self.post(.captureFinished(outcome, thumbnail: thumbnail))
            let uniqueID = finished.uniqueID
            self.sessionQueue.async {
                // Leak guard: removed on every path.
                self.delegates[uniqueID] = nil
                if case .savePending = outcome {
                    self.post(.pendingSaves(self.fileStore.pendingItems().count))
                }
            }
        }

        let delegate = PhotoCaptureDelegate(processor: processor)
        delegates[settings.uniqueID] = delegate
        readinessCoordinator?.startTrackingCaptureRequest(using: settings)
        post(.captureStarted)
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    // MARK: - Pending saves (§11)

    func retryPendingSaves(cleanOrphans: Bool = false) {
        let store = fileStore
        let saver = self.saver
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if cleanOrphans { store.removeOrphans() }
            let items = store.pendingItems()
            guard !items.isEmpty else {
                self.post(.pendingSaves(0))
                return
            }
            let group = DispatchGroup()
            for item in items {
                group.enter()
                saver.save(item) { result in
                    if case .success(let destination) = result, destination == .photoLibrary {
                        store.remove(item.id)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .global(qos: .utility)) {
                self.post(.pendingSaves(store.pendingItems().count))
            }
        }
    }

    // MARK: - Live values (≤15 Hz)

    private func startLiveTimer() {
        guard liveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 15.0, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            self?.sampleLiveValues()
        }
        timer.resume()
        liveTimer = timer
    }

    private func stopLiveTimer() {
        liveTimer?.cancel()
        liveTimer = nil
    }

    private func sampleLiveValues() {
        guard let wrapper = activeCameraDevice else { return }
        let device = wrapper.device
        let values = LiveDeviceValues(
            iso: device.iso,
            shutter: wrapper.currentDuration,
            lensPosition: device.lensPosition,
            temperature: wrapper.currentWhiteBalance.temperature,
            aperture: device.lensAperture,
            meterOffset: device.exposureTargetOffset,
            isAdjustingFocus: device.isAdjustingFocus
        )
        runAutoISOLoop(device: wrapper)
        guard values.differsNoticeably(from: lastLive) else { return }
        lastLive = values
        post(.live(values))
    }

    /// One tick of the emulated auto-ISO loop (15 Hz). Uses the ISO the device actually metered
    /// with, so a frame of meter latency causes no overshoot (`ExposureLoopMath`).
    private func runAutoISOLoop(device: AVCameraDevice) {
        guard let loop = autoISOLoop else { return }
        let limits = device.limits
        if loopISO <= 0 { loopISO = device.currentISO }
        guard let next = ExposureLoopMath.nextISO(
            commanded: loopISO,
            observed: device.currentISO,
            meterOffset: device.exposureTargetOffset,
            bias: loop.bias,
            minISO: limits.minISO,
            maxISO: limits.maxISO
        ) else { return }
        loopISO = next
        if let aperture = loop.aperture, limits.exposure.supportsManualAperture {
            deviceController.submit(.exposure(.priority(aperture: aperture, duration: loop.duration, iso: next, bias: 0)))
        } else {
            deviceController.submit(.exposure(.custom(iso: next, duration: loop.duration)))
        }
    }

    // MARK: - Interruptions and errors (§11)

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            let reasonValue = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = reasonValue.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.post(.interrupted(Self.describe(reason)))
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.post(.interruptionEnded)
            self.resume()
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self.sessionQueue.async {
                self.handleRuntimeError(error)
            }
        })
        notificationTokens.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.handleSubjectAreaChange()
            }
        })
    }

    /// The tapped subject moved away: return focus (and metering in auto) to the centre,
    /// unless the user is focusing manually.
    private func handleSubjectAreaChange() {
        let centre = CGPoint(x: 0.5, y: 0.5)
        deviceController.submit(.focus(.continuousAuto(point: centre)))
        if case .some(.auto) = deviceController.exposureState {
            deviceController.submit(.exposurePoint(centre))
        }
    }

    private func handleRuntimeError(_ error: AVError?) {
        logger.error("Session runtime error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        if error?.code == .mediaServicesWereReset {
            rebuildSession()
            return
        }
        guard wantsRunning else { return }
        if !didRetryAfterError {
            didRetryAfterError = true
            session.startRunning()
            if session.isRunning {
                post(.running(true))
                return
            }
        }
        post(.running(false))
        post(.sessionFailed(error?.localizedDescription ?? "The camera stopped unexpectedly."))
    }

    /// After a media-services reset every input and output is rebuilt.
    private func rebuildSession() {
        stopLiveTimer()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        inputs.removeAll()
        delegates.removeAll()
        photoOutput = AVCapturePhotoOutput()
        videoDataOutput = AVCaptureVideoDataOutput()
        readinessCoordinator = nil
        isConfigured = false
        let lens = activeLens ?? catalog.defaultLens
        activeInput = nil
        activeLens = nil
        configureSession(initialLens: lens)
        startRunningIfNeeded()
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        switch reason {
        case .some(.videoDeviceNotAvailableInBackground):
            return "Camera paused in the background"
        case .some(.audioDeviceInUseByAnotherClient):
            return "Audio in use by another app"
        case .some(.videoDeviceInUseByAnotherClient):
            return "Camera in use by another app"
        case .some(.videoDeviceNotAvailableWithMultipleForegroundApps):
            return "Camera unavailable in Split View"
        case .some(.videoDeviceNotAvailableDueToSystemPressure):
            return "Camera paused: device too hot"
        default:
            return "Camera interrupted"
        }
    }
}

extension CaptureEngine: AVCapturePhotoOutputReadinessCoordinatorDelegate {
    func readinessCoordinator(_ coordinator: AVCapturePhotoOutputReadinessCoordinator, captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness) {
        post(.readiness(captureReadiness == .ready))
    }
}
