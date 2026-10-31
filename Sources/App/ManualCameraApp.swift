import SwiftUI

/// The single controller for the app's lifetime, created lazily on the main actor.
@MainActor
enum AppServices {
    static let controller = CameraController()
}

@main
struct ManualCameraApp: App {
    var body: some Scene {
        WindowGroup {
            CameraView(controller: AppServices.controller)
                .preferredColorScheme(.dark)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
