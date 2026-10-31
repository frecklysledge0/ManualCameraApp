import CoreHaptics
import UIKit

/// Every haptic the app plays (Slice 1 §12, Slice 2 §10). Patterns are
/// (intensity, sharpness, time offset in seconds).
enum HapticEvent: CaseIterable, Hashable, Sendable {
    case shutterPress
    case saved
    case lensSwitch
    case detent
    case limit
    case focusLock
    case focusSnap
    case level
    case modeChange
    /// Very light tick for the MF wheel (every 1/50 of travel).
    case focusTick
    /// Turning the Medium Format Edition on or off (Slice 3 §3).
    case edition
    /// The Edition's shutter: softer than `shutterPress` (Slice 3 §8).
    case leafShutter

    struct Transient: Sendable {
        let intensity: Float
        let sharpness: Float
        let time: TimeInterval
    }

    var transients: [Transient] {
        switch self {
        case .shutterPress:
            return [Transient(intensity: 1.0, sharpness: 0.7, time: 0), Transient(intensity: 0.6, sharpness: 0.3, time: 0.035)]
        case .saved:
            return [Transient(intensity: 0.35, sharpness: 0.2, time: 0)]
        case .lensSwitch:
            return [Transient(intensity: 0.8, sharpness: 0.2, time: 0)]
        case .detent:
            return [Transient(intensity: 0.45, sharpness: 0.9, time: 0)]
        case .limit:
            return [Transient(intensity: 0.7, sharpness: 1.0, time: 0)]
        case .focusLock:
            return [Transient(intensity: 0.6, sharpness: 0.6, time: 0)]
        case .focusSnap:
            return [Transient(intensity: 0.5, sharpness: 1.0, time: 0), Transient(intensity: 0.5, sharpness: 1.0, time: 0.018)]
        case .level:
            return [Transient(intensity: 0.4, sharpness: 0.5, time: 0)]
        case .modeChange:
            return [Transient(intensity: 0.7, sharpness: 0.4, time: 0)]
        case .focusTick:
            return [Transient(intensity: 0.22, sharpness: 0.9, time: 0)]
        case .edition:
            return [Transient(intensity: 0.45, sharpness: 0.2, time: 0), Transient(intensity: 0.25, sharpness: 0.1, time: 0.07)]
        case .leafShutter:
            return [Transient(intensity: 0.55, sharpness: 0.35, time: 0), Transient(intensity: 0.35, sharpness: 0.8, time: 0.028)]
        }
    }
}

/// Core Haptics engine with pre-built pattern players, so a detent costs one `start` call.
/// Falls back to `UIImpactFeedbackGenerator` on hardware without Core Haptics.
@MainActor
final class HapticsEngine {

    var isEnabled = true
    /// Global intensity multiplier (0.5…1.0).
    var intensityScale: Float = 1.0 {
        didSet {
            guard oldValue != intensityScale else { return }
            rebuildPlayers()
        }
    }

    private let supportsHaptics: Bool
    private var engine: CHHapticEngine?
    private var isRunning = false
    private var players: [HapticEvent: CHHapticPatternPlayer] = [:]
    private lazy var fallbackLight = UIImpactFeedbackGenerator(style: .light)
    private lazy var fallbackRigid = UIImpactFeedbackGenerator(style: .rigid)

    init() {
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        if supportsHaptics {
            createEngine()
        }
    }

    func play(_ event: HapticEvent) {
        guard isEnabled else { return }
        guard supportsHaptics else {
            playFallback(event)
            return
        }
        if !isRunning {
            startEngine()
        }
        guard isRunning, let player = players[event] else {
            playFallback(event)
            return
        }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // The engine may have stopped between checks; restart it for the next event.
            isRunning = false
        }
    }

    /// Restarts the engine after the app returns to the foreground.
    func resume() {
        guard supportsHaptics, !isRunning else { return }
        startEngine()
    }

    // MARK: - Engine lifecycle

    private func createEngine() {
        do {
            let newEngine = try CHHapticEngine()
            newEngine.playsHapticsOnly = true
            newEngine.isAutoShutdownEnabled = false
            newEngine.stoppedHandler = { @Sendable [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.isRunning = false }
            }
            newEngine.resetHandler = { @Sendable [weak self] in
                guard let self else { return }
                Task { @MainActor in self.handleReset() }
            }
            engine = newEngine
            startEngine()
        } catch {
            engine = nil
        }
    }

    private func startEngine() {
        guard let engine else { return }
        do {
            try engine.start()
            isRunning = true
            if players.isEmpty { rebuildPlayers() }
        } catch {
            isRunning = false
        }
    }

    private func handleReset() {
        // After a reset every player is invalid: restart and rebuild them.
        players.removeAll()
        isRunning = false
        startEngine()
        rebuildPlayers()
    }

    private func rebuildPlayers() {
        guard let engine else { return }
        var rebuilt: [HapticEvent: CHHapticPatternPlayer] = [:]
        for event in HapticEvent.allCases {
            let events = event.transients.map { transient in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, transient.intensity * intensityScale)),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: transient.sharpness)
                    ],
                    relativeTime: transient.time
                )
            }
            if let pattern = try? CHHapticPattern(events: events, parameters: []),
               let player = try? engine.makePlayer(with: pattern) {
                rebuilt[event] = player
            }
        }
        players = rebuilt
    }

    private func playFallback(_ event: HapticEvent) {
        let peak = event.transients.map(\.intensity).max() ?? 0.5
        let intensity = CGFloat(min(1, peak * intensityScale))
        if event.transients.first.map({ $0.sharpness >= 0.6 }) ?? false {
            fallbackRigid.impactOccurred(intensity: intensity)
        } else {
            fallbackLight.impactOccurred(intensity: intensity)
        }
    }
}
