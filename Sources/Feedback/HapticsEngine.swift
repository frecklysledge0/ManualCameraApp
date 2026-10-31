import CoreHaptics
import UIKit

/// Every haptic the app plays (§12). Patterns are (intensity, sharpness, time offset in seconds).
enum HapticEvent: CaseIterable, Hashable, Sendable {
    case shutterPress
    case saved
    case lensSwitch
    case detent
    case limit

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
