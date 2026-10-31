import Foundation
import Observation
import UIKit

enum CameraAuthorization: Equatable, Sendable {
    case unknown
    case authorized
    case denied
    case restricted
}

/// A message strip shown over the HUD (§11).
struct Banner: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        case openSettings
        case retrySave
        case retrySession
    }

    enum Kind: String, Sendable {
        case photosDenied
        case lowStorage
        case criticalStorage
        case saveFailed
        case sessionFailed
        case thermal
        case noCamera
    }

    var kind: Kind
    var message: String
    var action: Action
    var id: String { kind.rawValue }

    var actionTitle: String? {
        switch action {
        case .none: return nil
        case .openSettings: return "Settings"
        case .retrySave: return "Retry save"
        case .retrySession: return "Retry"
        }
    }
}

/// Where the tap-to-focus box is drawn (view points). `id` changes on every tap to restart its animation.
struct FocusIndicator: Equatable, Sendable {
    var point: CGPoint
    var id: Int
}

/// Capture and session status for the HUD.
@Observable
@MainActor
final class CaptureStatus {
    var authorization: CameraAuthorization = .unknown
    var isSessionRunning = false
    /// From `AVCapturePhotoOutputReadinessCoordinator`. While false the shutter dims and presses
    /// give a `limit` haptic instead of queueing silently.
    var isReady = false
    var inFlightCount = 0
    var lastThumbnail: UIImage?
    /// Interruption reason while the session is interrupted (call, Split View, other camera app).
    var interruption: String?
    var isSwitchingLens = false
    /// Increments at every `willCapturePhoto`, which drives the screen flash.
    var flashCounter = 0
    var viewfinder = ViewfinderGeometry.zero
    var pendingSaveCount = 0
    var focusIndicator: FocusIndicator?
    private(set) var banners: [Banner] = []

    var canCapture: Bool {
        authorization == .authorized && isSessionRunning && isReady && interruption == nil
    }

    func show(_ banner: Banner) {
        if let index = banners.firstIndex(where: { $0.kind == banner.kind }) {
            banners[index] = banner
        } else {
            banners.append(banner)
        }
    }

    func dismiss(_ kind: Banner.Kind) {
        banners.removeAll { $0.kind == kind }
    }
}
