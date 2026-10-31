# Slice 1 — Stabilize: Design Spec

**Date:** 2026-10-30 · **Status:** Draft, awaiting Rohit's review · **Roadmap:** `2026-10-30-camera-roadmap.md`

## 1. Goal
Make the existing app smooth, correct and reliable without changing its look. When this slice is done:
- The UI runs at 120 Hz on ProMotion with no hitches, even while dragging sliders with peaking on.
- Every shutter press produces exactly one correct, upright Photos item.
- Lens switches and device rotation never show a black flash or a layout jump.
- Every hardware-like interaction gets a crisp Core Haptics response.

This slice also builds the internal structure that Slices 2 and 3 depend on.

## 2. Decisions (stated by Rohit)
- iPhone 18 Pro Max is the primary device. The minimum target is iOS 17, and features are gated on capability.
- One shutter press saves **one Photos item: ProRAW + HEIF**. A RAW toggle switches to HEIF-only.
- Approach B: restructure the core and keep the current UI.

**Decisions made in this spec (please check):**
- The **interface is locked to portrait**. Readouts and glyphs rotate in place with the device, as in Apple's Camera app. The UI never re-lays out on rotation, and photos are still saved upright in landscape.
- The **separate physical lenses are kept**, not a virtual multi-camera device, so manual exposure is always honoured. The lens-switch hitch is hidden by preparing inputs ahead of time and cross-fading the last frame.

## 3. Scope
**In:** every audit fix below, the core restructure, the capture pipeline, rotation, lens switching, the haptics engine, lifecycle and error handling, a unit test target, and on-device performance verification.

**Out (later slices):** the new UI, P/A/S/M modes, aperture, the MF wheel, the loupe, zebras, the level redesign, themes, and colour science.

## 4. Audit findings → fixes
| ID | Problem (current code) | Fix |
|----|------------------------|-----|
| F1 | `ImagePipelineProcessor` builds a full-res `CGImage`→`UIImage` every frame for peaking, and publishes `nil` every frame when peaking is off. The histogram also publishes every frame. All of it goes through one `ObservableObject`, so the whole `CameraView` re-renders 30–60×/s. | Metal peaking drawn straight into an overlay layer (§6.2). Telemetry lives in its own `@Observable`, throttled to ≤30 Hz, and only leaf views read it. Nothing is published when nothing changed. |
| F2 | `MotionManager` publishes roll/pitch to the main queue at 60 Hz. | Sample on a private `OperationQueue`, publish ≤30 Hz, and only when the change exceeds 0.1°. |
| F3 | `CADisableMinimumFrameDurationOnPhone` is missing, so the UI is capped at 60 Hz. | Add it to `Info.plist` (`true`). |
| F4 | RAW + HEVC settings trigger two `didFinishProcessingPhoto` callbacks, and each one saves a separate asset (duplicates). | `PhotoCaptureProcessor` collects both and saves one `PHAssetCreationRequest`: `.photo` (HEIF) + `.alternatePhoto` (DNG file URL, `shouldMoveFile = true`). |
| F5 | `availableRawPhotoPixelFormatTypes.first` may not be ProRAW. | Filter with `AVCapturePhotoOutput.isAppleProRAWPixelFormat(_:)`. Fall back to Bayer RAW, then to HEIF-only (RAW toggle hidden). |
| F6 | `photoQualityPrioritization` is never set, so the system can override manual ISO and shutter in dark scenes. | Use `.speed` whenever exposure is custom and `.balanced` in Auto. |
| F7 | The EV slider forces `.continuousAutoExposure`, which wipes manual ISO and shutter. Tap-to-focus resets exposure to auto. | EV is active only in AUTO. In MANUAL, show the meter offset (`exposureTargetOffset`) read-only. Tap-to-focus in MANUAL changes focus only. |
| F8 | The shutter slider is linear over ~1/40000…1 s, and its readout shows `0.0`. The ISO slider is linear, and ISO starts at `minISO`. | Log-scale sliders on 1/3-stop tables with detents. Readout as a fraction. On entering MANUAL, lock to the current auto values (`AVCaptureDevice.currentISO` / `exposureDurationCurrent`) so the exposure does not jump. |
| F9 | No rotation handling: landscape photos have the wrong orientation, peaking is hardcoded `.oriented(.right)`, and its overlay gravity does not match the preview. | `RotationController` built on `AVCaptureDevice.RotationCoordinator` (§9). A shared `ViewfinderGeometry` drives preview, overlay and tap mapping. |
| F10 | Tap-to-focus uses hand-written coordinate math. | `previewLayer.captureDevicePointConverted(fromLayerPoint:)`. |
| F11 | Lens switch creates inputs on demand, so the user sees a black frame and a hitch. The "5x" label is hardcoded. | Inputs created at startup, plus a cross-fade (§8). Labels computed from the device (§8). |
| F12 | No handling for interruptions, runtime errors or thermal pressure. | §11. |
| F13 | Flash, HDR and RAW pills are non-functional stubs. | RAW pill wired to the RAW toggle. Flash and HDR removed until a slice designs them. |
| F14 | `UIRequiredDeviceCapabilities` = `armv7`, Swift version 5.0, an unneeded full `NSPhotoLibraryUsageDescription`, and `generate_project.rb` only globs `Sources/*.swift`. | Use `arm64` and Swift 5.9, keep add-only Photos access, glob recursively, and add a test target. |
| F15 | `isFrontCamera` is duplicated between the view and the manager, and focus is "transferred" across lenses although `lensPosition` is not comparable between lenses. | One source of truth in `CameraSettings`. Focus returns to AF on a lens change unless the user is in MF (the distance-based fix comes in Slice 2). |

## 5. Architecture
**Main rule:** views never touch AVFoundation, and `CaptureEngine` never touches SwiftUI. They communicate only through the state objects and engine commands.

```
Sources/
  App/        ManualCameraApp.swift
  Capture/    CaptureEngine.swift          owns AVCaptureSession, inputs/outputs, private sessionQueue
              CameraDevice.swift           protocol over AVCaptureDevice (enables fakes in tests)
              DeviceCatalog.swift          discovers lenses, zoom labels, capabilities
              PhotoCaptureProcessor.swift  one per shot; RAW+HEIF → single Photos item
              RotationController.swift     RotationCoordinator → preview/capture/video angles
              ExposureMath.swift           stop tables, log mapping, clamping (pure)
  State/      CameraSettings.swift   @Observable @MainActor: mode, iso, shutter, ev, wb, focus, lens,
                                     position, rawEnabled, device limits, capabilities
              LiveTelemetry.swift    @Observable @MainActor: histogram, roll, pitch, meterOffset
              CaptureStatus.swift    @Observable @MainActor: isReady, inFlightCount, lastThumbnail, banner
  Pipeline/   FramePipeline.swift        AVCaptureVideoDataOutput delegate; Metal compute
              PeakingOverlayView.swift   UIView backed by CAMetalLayer
              Shaders.metal              peaking, downsample, histogram kernels
  Feedback/   HapticsEngine.swift
  Motion/     MotionSampler.swift
  UI/         CameraView.swift (slimmed), Controls/, Overlays/   (same look as today)
Tests/        ExposureMathTests, DeviceCatalogTests, CaptureEngineTests,
              PhotoCaptureProcessorTests, RotationTests
```

**Concurrency:** `CaptureEngine` is a `final class` whose mutable state is confined to `sessionQueue`. It hops to `@MainActor` only to write state objects. `FramePipeline` runs on its own `videoQueue` (QoS `.userInteractive`). State objects are `@MainActor`. Swift 5.9 with strict concurrency set to "targeted".

## 6. Data flow

### 6.1 User input → hardware
`View` → `CameraSettings` (main, updated optimistically) → `engine.send(.exposure(iso:, duration:))` → the engine **coalesces** on `sessionQueue` (latest wins, at most one `lockForConfiguration` per frame interval). Slider drags at 120 events/s therefore do not thrash the device lock. → `setExposureModeCustom` completion → the engine writes the *applied* (clamped) values back to `CameraSettings`.

### 6.2 Frames → overlays
- `AVCaptureVideoDataOutput` uses `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (cheaper than BGRA, and the luma plane feeds peaking directly), with `alwaysDiscardsLateVideoFrames = true`.
- `CVMetalTextureCache` gives zero-copy textures.
- **Peaking:** a compute kernel (Sobel magnitude on luma, threshold) renders directly into `PeakingOverlayView`'s `CAMetalLayer` drawable on `videoQueue`. No `UIImage`, no main-thread hop. When peaking is off, the kernel is skipped and the layer is cleared once.
- **Histogram:** downscale to 256×192 on the GPU, then a 256-bin RGB histogram kernel. Runs every Nth frame so it publishes at ≤30 Hz, and only if bins changed by more than ε. `HistogramView` draws with `Canvas`.
- No per-frame allocations: buffers, textures and command-buffer descriptors are reused.

### 6.3 Capture
1. Shutter press → `HapticsEngine.shutterPress()` fires immediately on main.
2. `engine.capture()` on `sessionQueue` builds settings from the prepared template.
3. A `PhotoCaptureProcessor` is created and stored in a dictionary keyed by `uniqueID`.
4. `willCapturePhoto` → screen-flash animation. It is tied to the real exposure, not to the button press.
5. `didFinishProcessingPhoto`:
   - RAW → `fileDataRepresentation()` written straight to a temp `.dng` URL, then the `Data` is released.
   - Processed → HEIF `Data` held.
6. `didFinishCaptureFor` → one `PHAssetCreationRequest` (`.photo` HEIF + `.alternatePhoto` DNG URL with `shouldMoveFile`) → thumbnail into `CaptureStatus` → `HapticsEngine.saved()` → the processor is removed from the dictionary. **Leak guard:** it is removed on every path, success or error.

**Readiness:** `AVCapturePhotoOutputReadinessCoordinator` drives `CaptureStatus.isReady`. While it is not ready, the shutter button dims and presses give a "limit" haptic instead of queuing silently.

## 7. Capture configuration
- Session preset `.photo`. Use the active format that supports ProRAW at the highest `supportedMaxPhotoDimensions` and the highest available frame rate (§10).
- `isAppleProRAWEnabled = true` when supported. `maxPhotoQualityPrioritization = .quality`.
- Where supported (iOS 17+): `isResponsiveCaptureEnabled`, `isFastCapturePrioritizationEnabled`, `isZeroShutterLagEnabled`. **Verify on device** how each interacts with ProRAW, and record the results in the plan.
- `setPreparedPhotoSettingsArray` with both the RAW+HEIF and the HEIF-only templates at session start and whenever the RAW toggle changes.
- The RAW toggle is persisted with `@AppStorage("rawEnabled")` and defaults to on.

## 8. Lens switching
- `DeviceCatalog` uses `AVCaptureDevice.DiscoverySession` for `[.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]` on the back, plus the front wide camera.
- **Zoom labels:** read `virtualDeviceSwitchOverVideoZoomFactors` from `.builtInTripleCamera` and normalise so the ultra-wide is 0.5×. That gives the real telephoto factor on any iPhone. If no triple camera exists, use a focal-length ratio heuristic.
- An `AVCaptureDeviceInput` is created for every lens at startup and cached.
- **Switch sequence:**
  1. The pipeline hands over its last frame as a texture.
  2. A blurred copy is shown over the preview.
  3. `beginConfiguration`, swap input, `commitConfiguration`.
  4. Re-apply settings, clamped to the new device's limits.
  5. On the first frame from the new device, a 180 ms cross-fade removes the snapshot.
  6. `HapticsEngine.lensSwitch()`.
- **Settings transfer:** ISO and shutter are clamped to the new limits. WB transfers. Focus returns to AF unless the mode is MF (see F15).

## 9. Rotation
- `Info.plist` supports portrait only. `RotationController` owns an `AVCaptureDevice.RotationCoordinator(device:previewLayer:)` per active device.
- **Preview:** `videoRotationAngleForHorizonLevelPreview` → preview connection.
- **Capture:** read `videoRotationAngleForHorizonLevelCapture` at the moment of capture and set it on the photo output connection.
- **Video data output:** set to the same angle as the preview so overlays line up with it.
- **UI:** a `deviceOrientation` value (from the coordinator's KVO) rotates glyphs and readouts with a 0.25 s spring. Layout never changes.
- **`ViewfinderGeometry`:** one struct describing the preview rect under `.resizeAspect`, shared by the preview, the overlays and tap mapping.

## 10. 120 Hz and frame budget
- `CADisableMinimumFrameDurationOnPhone = true`.
- **Main thread:** under 4 ms per frame during interaction (the frame budget at 120 Hz is 8.3 ms). `CameraView.body` reads only `CameraSettings` and `CaptureStatus`, never per-frame data.
- **Camera feed rate:** bounded by the active format. Among ProRAW-capable formats, pick the one with the highest `videoSupportedFrameRateRanges.maxFrameRate`, and set `activeVideoMinFrameDuration` to it. A debug-only HUD shows the measured feed fps and UI fps.
- **Thermal:** at `.serious`, the histogram drops to 10 Hz and peaking to half rate. At `.critical`, a banner appears and the feed drops to 30 fps.

## 11. Lifecycle and error handling
| Event | Behaviour |
|------|-----------|
| Camera permission denied or restricted | Full-screen message with an "Open Settings" button. The engine does not start. |
| Photos add permission denied | Capture still works, but files go to the app's Documents folder, and a banner explains this and links to Settings. |
| `AVCaptureSessionWasInterrupted` (call, Split View, another camera app) | Dimmed blurred preview with the reason. The shutter is disabled. Resume on `InterruptionEnded`. |
| `AVCaptureSessionRuntimeError` | If `mediaServicesWereReset`, rebuild the session. Otherwise restart once; if that fails, show a banner with a retry button. |
| Photos save fails | Keep the temp files, show a "Retry save" banner, and clear the temp files on success or at the next launch. |
| Low storage (< 500 MB free) | Warning banner. Below 150 MB, RAW is disabled automatically with an explanation. |
| Scene background / foreground | Stop / start on `sessionQueue`, keeping the existing behaviour. |
| Core Haptics engine stopped or reset | `stoppedHandler` / `resetHandler` restart it and rebuild the players. |

## 12. Haptics
`HapticsEngine` (Core Haptics) creates and starts the `CHHapticEngine` at launch and caches pattern players:

| Event | Pattern |
|------|---------|
| `shutterPress` | Transient (intensity 1.0, sharpness 0.7), then another transient at +35 ms (0.6, 0.3). Feels like a mechanical shutter. |
| `saved` | Soft transient (0.35, 0.2). |
| `lensSwitch` | Transient (0.8, 0.2). |
| `detent` | Transient (0.45, 0.9), fired on every 1/3-stop crossing on sliders. |
| `limit` | Transient (0.7, 1.0) at a range end or a blocked shutter. |

If `supportsHaptics` is false, fall back to `UIImpactFeedbackGenerator`. The app has no audio input, so capture never suppresses haptics.

## 13. Testing and verification
**Unit tests (new `ManualCameraAppTests` target):**
- `ExposureMath`: stop tables, log mapping round-trips, clamping, fraction formatting.
- `DeviceCatalog`: zoom-label math from fake switch-over factors.
- `CaptureEngine` with a fake `CameraDevice`: command coalescing (100 commands produce ≤ N lock calls), the EV/manual rules, and clamping on lens switch.
- `PhotoCaptureProcessor` with fake photo payloads: exactly one asset request with two resources, the temp file is removed, and the processor is released on both the error path and the success path.
- `RotationController`: angle mapping for all four orientations.

**On-device checklist (iPhone 18 Pro Max, recorded in the plan with numbers):**
1. Instruments "Animation Hitches" during a 30 s slider drag with peaking on: hitch time ratio < 1 ms/s, and the UI stays at 120 fps.
2. 50 consecutive RAW+HEIF captures: memory returns to within ±30 MB of baseline, and the memory graph shows zero `PhotoCaptureProcessor` instances afterwards.
3. Press-to-`willCapturePhoto` latency is measured and logged for HEIF and RAW+HEIF. Target for HEIF: < 100 ms.
4. Each press creates exactly one Photos item with a RAW badge, and the DNG opens in Lightroom.
5. Portrait, landscape-left, landscape-right and upside-down shots are all saved upright.
6. Tap-to-focus lands where tapped, including the corners.
7. Lens switching 20× quickly shows no black frame and no crash.
8. A phone call during preview, and multitasking, recover cleanly.

## 14. Open items to verify on device (not design decisions)
- How ProRAW interacts with zero-shutter-lag and responsive capture.
- The actual maximum feed frame rate of ProRAW-capable formats on the 18 Pro Max.
- Whether `.builtInTripleCamera` switch-over factors match the labels in Apple's Camera app.
