# ManualCameraApp 📸

A manual iOS camera built with **SwiftUI**, **AVFoundation**, **Metal** and **Core Haptics**. It shoots ProRAW + HEIF as a single Photos item, runs its UI at 120 Hz on ProMotion, and gives every control a crisp haptic.

The upgrade plan lives in [`docs/superpowers/specs/2026-10-30-camera-roadmap.md`](docs/superpowers/specs/2026-10-30-camera-roadmap.md). Each slice has a spec in `docs/superpowers/specs/` and a plan / record in `docs/superpowers/plans/`.

## Features
- **Pro interface:** a telemetry strip above an uncovered 4:3 viewfinder, a Quick Fn bar (MODE · F · SS · ISO · EV · WB · FOCUS · Fn) and drum dials with 1/3-stop detents, flings and haptics. Long-press a tile to return it to AUTO.
- **P / A / S / M**, with Auto ISO in M and metered-manual (M.M.) read-out. Mode changes lock the live values, so the image never jumps. On iPhone 18 Pro (iOS 27) A/S/M drive the variable aperture (ƒ/1.48–ƒ/4). Elsewhere S is emulated with a smooth auto-ISO loop.
- **Focus:** AF-S with lock confirmation, AF-C, and an MF wheel with velocity-dependent gain, a focus-snap haptic at peak sharpness, a 4×/8× loupe from the native-resolution frame and focus peaking (5 colours, 3 levels).
- **Exposure aids:** RGB/luma histogram with clip markers, animated zebras, a two-axis level and shots left.
- **White balance:** AWB, presets and 2500–10000 K, plus tint.
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
  UI/         Theme/ (CameraTheme tokens + component styles, Branding), Components/ (DialView, MFWheel,
              HistogramView…), Strip/, Tray/ (Fn bar, dial tray), Sheets/ (Fn sheet), Overlays/;
              leaf views read per-frame data so the root never re-renders per frame
Tests/ManualCameraAppTests/   unit tests (⌘U)
tools/generate_xcodeproj.py   regenerates the Xcode project from the folders
```
Views never touch AVFoundation, and `CaptureEngine` never touches SwiftUI. They meet only in the state objects and the controller.

## Building
- Xcode with the iOS 17+ SDK (the iPhone 18 Pro Max needs an Xcode that supports its iOS version). Minimum deployment target: iOS 17.
- Open `ManualCameraApp.xcodeproj`, pick your team under *Signing & Capabilities* if needed, and run on a device. The camera doesn't work in the Simulator, but the unit tests do.
- After adding or removing files, run `python3 tools/generate_xcodeproj.py` to refresh the project.
- The variable-aperture code needs the iOS 27 SDK. If you build with an older Xcode, remove `IOS27_APERTURE_API` from *Active Compilation Conditions*.
