import CoreGraphics
import Foundation

/// Runs deferred work. In the app it is backed by the engine's `sessionQueue`; tests use a fake
/// with a manual clock.
protocol CommandScheduler: AnyObject {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

final class QueueScheduler: CommandScheduler {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        if delay <= 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}

/// Coalesces device commands (§6.1). Every command lands in a slot (exposure, white balance,
/// focus, metering point) where the latest value wins, and all slots are applied under a single
/// `lockForConfiguration` at most once per `minimumInterval`. A 120 Hz slider drag therefore costs
/// at most one device lock per camera frame.
///
/// Not thread-safe: confine it to one queue (the engine's `sessionQueue`).
final class DeviceController {

    private let scheduler: CommandScheduler
    /// Shortest time between two device locks; the engine sets it to the feed's frame duration.
    var minimumInterval: TimeInterval
    /// Called after each flush with the values that were actually applied (clamped).
    var onApplied: ((AppliedDeviceState) -> Void)?
    /// Called when locking the device failed repeatedly and the pending commands were dropped.
    var onLockFailure: ((Error) -> Void)?

    private(set) var device: CameraDevice?
    private(set) var exposureState: AppliedExposure?
    /// Number of `lockForConfiguration` calls made (diagnostics and tests).
    private(set) var lockCount = 0

    private var pendingExposure: ExposureCommand?
    private var pendingWhiteBalance: WhiteBalanceCommand?
    private var pendingFocus: FocusCommand?
    private var pendingExposurePoint: CGPoint?
    // Last command per slot, replayed on a new device by `bind(_:reapply:)`.
    private var lastExposure: ExposureCommand?
    private var lastWhiteBalance: WhiteBalanceCommand?
    private var lastFocus: FocusCommand?
    private var flushScheduled = false
    private var lastFlush: TimeInterval = -.greatestFiniteMagnitude
    private var failedAttempts = 0
    private let maxAttempts = 3

    init(scheduler: CommandScheduler, minimumInterval: TimeInterval = 1.0 / 60.0) {
        self.scheduler = scheduler
        self.minimumInterval = minimumInterval
    }

    var hasPendingCommands: Bool {
        pendingExposure != nil || pendingWhiteBalance != nil || pendingFocus != nil || pendingExposurePoint != nil
    }

    /// Switches to a new device. Pending commands are kept and clamped to the new limits.
    ///
    /// With `reapply`, the last exposure and white-balance commands are applied again right away so
    /// the new lens starts with the user's settings (§8). Focus returns to continuous AF unless the
    /// user was in manual focus (F15: lens positions are not comparable between lenses, so MF keeps
    /// the raw position until Slice 2 maps it by distance).
    func bind(_ newDevice: CameraDevice?, reapply: Bool = false) {
        device = newDevice
        exposureState = nil
        failedAttempts = 0
        if reapply, newDevice != nil {
            if pendingExposure == nil, let lastExposure { pendingExposure = lastExposure }
            if pendingWhiteBalance == nil, let lastWhiteBalance { pendingWhiteBalance = lastWhiteBalance }
            if pendingFocus == nil {
                if case .some(.locked) = lastFocus {
                    pendingFocus = lastFocus
                } else {
                    pendingFocus = .continuousAuto(point: nil)
                }
            }
            flush()
        } else if hasPendingCommands {
            scheduleFlush()
        }
    }

    /// Forgets the remembered commands (used when the user returns everything to AUTO).
    func resetRemembered() {
        lastExposure = nil
        lastWhiteBalance = nil
        lastFocus = nil
    }

    func submit(_ command: DeviceCommand) {
        merge(command)
        scheduleFlush()
    }

    /// Applies everything pending right away (used before capture and after a lens switch).
    func flushNow() {
        flush()
    }

    // MARK: - Merging

    private func merge(_ command: DeviceCommand) {
        switch command {
        case .exposure(let exposure):
            mergeExposure(exposure)
        case .whiteBalance(let whiteBalance):
            pendingWhiteBalance = whiteBalance
            lastWhiteBalance = whiteBalance
        case .focus(let focus):
            pendingFocus = focus
            lastFocus = focus
        case .exposurePoint(let point):
            pendingExposurePoint = point
        }
    }

    private func mergeExposure(_ command: ExposureCommand) {
        switch command {
        case .bias(let bias):
            switch pendingExposure {
            case .some(.auto):
                pendingExposure = .auto(bias: bias)
            case .some(.priority(let aperture, let duration, let iso, _)):
                pendingExposure = .priority(aperture: aperture, duration: duration, iso: iso, bias: bias)
            case .some(.custom):
                // F7: EV has no meaning while exposure is manual.
                break
            case .some(.bias), .none:
                pendingExposure = .bias(bias)
            }
        case .auto, .custom, .priority:
            pendingExposure = command
        }
        if let pendingExposure {
            switch pendingExposure {
            case .bias(let bias):
                switch lastExposure {
                case .some(.custom):
                    break
                case .some(.priority(let aperture, let duration, let iso, _)):
                    lastExposure = .priority(aperture: aperture, duration: duration, iso: iso, bias: bias)
                default:
                    lastExposure = .auto(bias: bias)
                }
            case .auto, .custom, .priority:
                lastExposure = pendingExposure
            }
        }
    }

    // MARK: - Flushing

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let wait = max(0, lastFlush + minimumInterval - scheduler.now)
        scheduler.schedule(after: wait) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flush()
        }
    }

    private func flush() {
        guard hasPendingCommands else { return }
        guard let device else { return }

        do {
            try device.lockForConfiguration()
        } catch {
            lockCount += 1
            failedAttempts += 1
            if failedAttempts >= maxAttempts {
                failedAttempts = 0
                clearPending()
                onLockFailure?(error)
            } else {
                lastFlush = scheduler.now
                scheduleFlush()
            }
            return
        }
        lockCount += 1
        failedAttempts = 0
        lastFlush = scheduler.now

        let limits = device.limits
        var applied = AppliedDeviceState()

        if let exposure = pendingExposure {
            applied.exposure = apply(exposure, to: device, limits: limits)
        }
        if let point = pendingExposurePoint, limits.supportsExposurePointOfInterest {
            // Tap-to-focus in manual exposure changes focus only (F7).
            if !(exposureState?.isFullyManual ?? false) {
                device.applyExposurePoint(clampPoint(point))
            }
        }
        if let whiteBalance = pendingWhiteBalance {
            applied.whiteBalance = apply(whiteBalance, to: device, limits: limits)
        }
        if let focus = pendingFocus {
            applied.focus = apply(focus, to: device, limits: limits)
        }
        device.unlockForConfiguration()
        clearPending()

        if !applied.isEmpty {
            onApplied?(applied)
        }
    }

    private func clearPending() {
        pendingExposure = nil
        pendingWhiteBalance = nil
        pendingFocus = nil
        pendingExposurePoint = nil
    }

    private func apply(_ command: ExposureCommand, to device: CameraDevice, limits: DeviceLimits) -> AppliedExposure? {
        switch command {
        case .auto(let bias):
            let clamped = limits.clampBias(bias)
            device.applyContinuousAutoExposure(bias: clamped)
            exposureState = .auto(bias: clamped)
            return exposureState
        case .bias(let bias):
            let clamped = limits.clampBias(bias)
            switch exposureState {
            case .some(.custom):
                return nil
            case .some(.priority(let aperture, let duration, let iso, _)):
                guard duration == nil || iso == nil else { return nil }
                device.applyExposureBias(clamped)
                exposureState = .priority(aperture: aperture, duration: duration, iso: iso, bias: clamped)
            default:
                device.applyExposureBias(clamped)
                exposureState = .auto(bias: clamped)
            }
            return exposureState
        case .priority(let aperture, let duration, let iso, let bias):
            guard limits.supportsPriorityExposure else { return nil }
            let safeAperture = aperture.map { limits.clampAperture($0) }
            let safeDuration = duration.map { limits.clampDuration($0) }
            let safeISO = iso.map { limits.clampISO($0) }
            let safeBias = limits.clampBias(bias)
            device.applyPriorityExposure(aperture: safeAperture, duration: safeDuration, iso: safeISO)
            if safeDuration == nil || safeISO == nil {
                device.applyExposureBias(safeBias)
            }
            exposureState = .priority(aperture: safeAperture, duration: safeDuration, iso: safeISO, bias: safeBias)
            return exposureState
        case .custom(let iso, let duration):
            guard limits.supportsCustomExposure else { return nil }
            let clampedISO = limits.clampISO(iso)
            let clampedDuration = limits.clampDuration(duration)
            device.applyCustomExposure(duration: clampedDuration, iso: clampedISO)
            exposureState = .custom(iso: clampedISO, duration: clampedDuration)
            return exposureState
        }
    }

    private func apply(_ command: WhiteBalanceCommand, to device: CameraDevice, limits: DeviceLimits) -> AppliedWhiteBalance? {
        switch command {
        case .auto:
            device.applyAutoWhiteBalance()
            let current = device.currentWhiteBalance
            return AppliedWhiteBalance(isAuto: true, temperature: current.temperature, tint: current.tint)
        case .locked(let temperature, let tint):
            guard limits.supportsLockedWhiteBalance else { return nil }
            let safeTemperature = ExposureMath.clamp(temperature, 1500, 15000)
            let safeTint = ExposureMath.clamp(tint, -150, 150)
            let achieved = device.applyLockedWhiteBalance(temperature: safeTemperature, tint: safeTint)
            return AppliedWhiteBalance(isAuto: false, temperature: achieved.temperature, tint: achieved.tint)
        }
    }

    private func apply(_ command: FocusCommand, to device: CameraDevice, limits: DeviceLimits) -> FocusCommand? {
        switch command {
        case .continuousAuto(let point):
            guard limits.supportsContinuousAutoFocus else { return nil }
            let safePoint = limits.supportsFocusPointOfInterest ? point.map(clampPoint) : nil
            let clampedCommand = FocusCommand.continuousAuto(point: safePoint)
            device.applyFocus(clampedCommand)
            return clampedCommand
        case .singleAuto(let point):
            guard limits.supportsSingleAutoFocus else { return nil }
            let safePoint = limits.supportsFocusPointOfInterest ? point.map(clampPoint) : nil
            let clampedCommand = FocusCommand.singleAuto(point: safePoint)
            device.applyFocus(clampedCommand)
            return clampedCommand
        case .locked(let position):
            guard limits.supportsLockedFocus else { return nil }
            let clampedCommand = FocusCommand.locked(lensPosition: ExposureMath.clamp(position, 0, 1))
            device.applyFocus(clampedCommand)
            return clampedCommand
        }
    }

    private func clampPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: ExposureMath.clamp(point.x, 0, 1), y: ExposureMath.clamp(point.y, 0, 1))
    }
}
