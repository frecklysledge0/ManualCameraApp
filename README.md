# ManualCameraApp 📸

A manual iOS camera built with **SwiftUI**, **AVFoundation**, **Metal** and **Core Haptics**. It shoots ProRAW + HEIF as a single Photos item, runs its UI at 120 Hz on ProMotion, and gives every control a crisp haptic.

The upgrade plan lives in [`docs/superpowers/specs/2026-10-30-camera-roadmap.md`](docs/superpowers/specs/2026-10-30-camera-roadmap.md). Each slice has a spec in `docs/superpowers/specs/` and a plan / record in `docs/superpowers/plans/`.

## Features
- **Manual exposure:** 1/3-stop shutter and ISO dials with detents. Entering MANUAL locks to the current auto values, so the image never jumps.
- **EV** (AUTO only) and a read-only meter offset in MANUAL. White balance in 100 K steps. Manual focus with Metal focus peaking.
- **One shutter press → one Photos item** (ProRAW DNG + HEIF), or HEIF only when RAW is off. Bayer RAW is the fallback on non-Pro phones.
- **Rotation-aware.** The UI stays in portrait, glyphs rotate in place, and photos are saved upright in every orientation.
- **Smooth lens switching.** Inputs are prepared at launch, a blurred last frame covers the swap, and zoom labels are read from the device (0.5×, 1×, 4× or 5×…).
- **Reliable.** Interruptions, runtime errors, Photos-denied (falls back to Files), failed saves (kept and retried), low storage and thermal pressure are all handled.

## Architecture
```
Sources/
  App/        app entry point
  Capture/    CaptureEngine (session queue), DeviceController (command coalescing), AVCameraDevice,
              DeviceCatalog, PhotoCaptureProcessor + delegate, PhotoLibrarySaver, CaptureFileStore,
              RotationController, pure maths (ExposureMath, LensMath, RotationMath, ViewfinderGeometry)
  State/      @Observable CameraSettings, LiveTelemetry, CaptureStatus; CameraController (intents)
  Pipeline/   FramePipeline (video-data delegate), MetalOverlayView, Shaders.metal
  Feedback/   HapticsEngine (Core Haptics)
  Motion/     MotionSampler (CoreMotion off the main thread)
  UI/         SwiftUI views; leaf views read per-frame data so the root never re-renders per frame
Tests/ManualCameraAppTests/   unit tests (⌘U)
tools/generate_xcodeproj.py   regenerates the Xcode project from the folders
```
Views never touch AVFoundation, and `CaptureEngine` never touches SwiftUI. They meet only in the state objects and the controller.

## Building
- Xcode with the iOS 17+ SDK (the iPhone 18 Pro Max needs an Xcode that supports its iOS version). Minimum deployment target: iOS 17.
- Open `ManualCameraApp.xcodeproj`, pick your team under *Signing & Capabilities* if needed, and run on a device. The camera doesn't work in the Simulator, but the unit tests do.
- After adding or removing files, run `python3 tools/generate_xcodeproj.py` to refresh the project.
