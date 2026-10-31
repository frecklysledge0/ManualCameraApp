# ManualCameraApp 📸

A manual iOS camera built with **SwiftUI**, **AVFoundation**, **Metal** and **Core Haptics**. It shoots ProRAW (or ProRAW + HEIF as a single Photos item), runs its UI at 120 Hz on ProMotion, gives every control a crisp haptic, and has a one-tap **Medium Format Edition** with its own colour look.

The upgrade plan lives in [`docs/superpowers/specs/2026-10-30-camera-roadmap.md`](docs/superpowers/specs/2026-10-30-camera-roadmap.md). Each slice has a spec in `docs/superpowers/specs/` and a plan / record in `docs/superpowers/plans/`.

## Features
- **Pro interface:** an Alpha-style status header (mode · AF · format · shots left · battery, histogram and level) above a full-width 4:3 viewfinder, a Quick Fn bar (MODE · F · SS · ISO · EV · WB · FOCUS · Fn) and drum dials with 1/3-stop detents, flings and haptics. Each value is shown once. Long-press a tile to return it to AUTO; tap the format badge to switch HEIF / RAW / RAW+HEIF.
- **Hardware shutter, Sony-style:** press Camera Control (iPhone 16 and later) or a volume button to focus at the focus frame (green when locked), release to shoot; in AF-S the shot waits for focus. A light press opens Camera Control's own Aperture, Exposure and Focus controls and focuses too.
- **P / A / S / M**, with Auto ISO in M and metered-manual (M.M.) read-out. Mode changes lock the live values, so the image never jumps. On iPhone 18 Pro (iOS 27) A/S/M drive the variable aperture (ƒ/1.48–ƒ/4) in 1/3 stops, wherever iOS accepts them. Elsewhere S is emulated with a smooth auto-ISO loop.
- **Focus:** a centre focus frame that stays where you tap (long-press to re-centre) and turns green when focus is achieved; AF-S with lock confirmation, AF-C, and an MF wheel with velocity-dependent gain, a focus-snap haptic at peak sharpness, a 4×/8× loupe from the native-resolution frame and focus peaking (5 colours, 3 levels).
- **Exposure aids:** RGB/luma histogram with clip markers, animated zebras, a two-axis level and shots left.
- **White balance:** AWB, presets and 2500–10000 K, plus tint.
- **Formats:** RAW (the DNG is the Photos item, so it shows as RAW/ProRAW), RAW+HEIF (one Photos item: HEIF with the DNG paired) or HEIF. Bayer RAW is the fallback on non-Pro phones.
- **Medium Format Edition** (Fn sheet): a calm monochrome interface with large read-outs and an arc dial; every shot is developed from RAW through *MF Natural Colour* (an original 65³ LUT), with 1:1 and XPAN framing, film-like blue-noise grain, a quiet leaf-shutter sound and a live preview of the look in the viewfinder.
- **Rotation-aware.** The UI stays in portrait, glyphs rotate in place, and photos are saved upright in every orientation.
- **Smooth lens switching.** Inputs are prepared at launch, a blurred last frame covers the swap, and zoom labels are read from the device (0.5×, 1×, 4× or 5×…).
- **Reliable.** Interruptions, runtime errors, Photos-denied (falls back to Files), failed saves (kept and retried), low storage and thermal pressure are all handled.

## Architecture
```
Sources/
  App/        app entry point
  Capture/    CaptureEngine (session queue), DeviceController (command coalescing), AVCameraDevice,
              Edition/ (EditionDeveloper, LookResources, framing/grain/ΔE maths, generated LookConstants),
              DeviceCatalog, PhotoCaptureProcessor + delegate, PhotoLibrarySaver, CaptureFileStore,
              RotationController, pure maths (ExposureMath, LensMath, RotationMath, ViewfinderGeometry)
  State/      @Observable CameraSettings, LiveTelemetry, CaptureStatus; CameraController (intents)
  Pipeline/   FramePipeline (video-data delegate), MetalOverlayView, EditionPreviewRenderer, Shaders.metal
  Feedback/   HapticsEngine (Core Haptics), ShutterSoundPlayer
  Motion/     MotionSampler (CoreMotion off the main thread)
  UI/         Theme/ (CameraTheme tokens + component styles, Branding), Components/ (DialView, MFWheel,
              HistogramView…), Strip/, Tray/ (Fn bar, dial tray), Sheets/ (Fn sheet), Overlays/;
              leaf views read per-frame data so the root never re-renders per frame
Tests/ManualCameraAppTests/   unit tests (⌘U)
Resources/                    MF Natural Colour LUT + look.json, blue-noise tile, leaf-shutter sound
tools/generate_xcodeproj.py   regenerates the Xcode project from the folders
tools/look/                   make_look.py (LUT + LookConstants from look.json), make_assets.py
```
Views never touch AVFoundation, and `CaptureEngine` never touches SwiftUI. They meet only in the state objects and the controller.

## Building
- Xcode with the iOS 17+ SDK (the iPhone 18 Pro Max needs an Xcode that supports its iOS version). Minimum deployment target: iOS 17.
- Open `ManualCameraApp.xcodeproj`, pick your team under *Signing & Capabilities* if needed, and run on a device. The camera doesn't work in the Simulator, but the unit tests do.
- After adding or removing files, run `python3 tools/generate_xcodeproj.py` to refresh the project.
- To change the look, edit `tools/look/look.json` and run `python3 tools/look/make_look.py` (needs numpy). It rewrites the LUT, `Resources/look.json` and `LookConstants.swift` together; a unit test fails if they drift apart.
- The variable-aperture code needs the iOS 27 SDK. If you build with an older Xcode, remove `IOS27_APERTURE_API` from *Active Compilation Conditions*.
