# Slice 1 — Stabilize: Implementation Plan and Record

**Spec:** `../specs/2026-10-30-slice1-stabilize-design.md` · **Status:** Implemented, waiting for an Xcode build and on-device verification

This file is both the plan and the record of what was built. Section 4 lists where the code differs from the spec and why.

## 1. Build steps (done)
1. **Project.** `tools/generate_xcodeproj.py` (standard-library Python only) replaces `generate_project.rb`. It globs `Sources/` recursively, adds `Resources/`, and adds a `ManualCameraAppTests` unit-test target and a shared scheme (F14).
2. **Info.plist.** Adds `CADisableMinimumFrameDurationOnPhone`, sets `arm64`, keeps only add-only Photos access, locks the interface to portrait, and turns on Files sharing for the Photos-denied fallback (F3, F14, §9, §11).
3. **Pure core.** `ExposureMath`, `LensMath`, `RotationMath`, `ViewfinderGeometry`, `StoragePolicy` and `WhiteBalanceMath`, all unit-tested.
4. **Device layer.** The `CameraDevice` protocol, the `AVCameraDevice` wrapper (every setter checks support and clamps, so AVFoundation can't throw a range exception) and `DeviceController`, which coalesces commands (§6.1).
5. **Capture.** `CaptureEngine` uses a session queue, prepared RAW and HEIF templates, the readiness coordinator, and ZSL, responsive and fast-capture prioritisation. `PhotoCaptureProcessor` saves one Photos item per press (F4, F5, F6, §6.3, §7). `CaptureFileStore` and `PhotoLibrarySaver` handle saving.
6. **Frames.** `FramePipeline` runs Metal peaking straight into a `CAMetalLayer` and a GPU histogram at 30 Hz or less (F1, §6.2). `Shaders.metal` holds the kernels.
7. **Rotation and lenses.** `RotationController` wraps `RotationCoordinator`. `DeviceCatalog` gives real zoom labels. Lens switches use cached inputs, a blurred snapshot and a cross-fade (F9, F10, F11, §8, §9).
8. **Feedback and motion.** `HapticsEngine` uses Core Haptics with a UIKit fallback (§12). `MotionSampler` samples off the main thread at 30 Hz or less (F2).
9. **State and UI.** `CameraSettings`, `LiveTelemetry` and `CaptureStatus` are `@Observable` and `@MainActor`, with `CameraController` holding the intents. The UI keeps today's look but reads state only in leaf views (F1, F7, F8, F13, F15).
10. **Lifecycle and errors (§11).** Permission screen, Photos-denied fallback to Files, interruption overlay, runtime-error restart and rebuild, save retry, storage policy and thermal policy.

## 2. Unit tests (`Tests/ManualCameraAppTests`)
| File | Covers |
|------|--------|
| `ExposureMathTests` | stop tables, endpoints, log mapping round-trips, clamping, formatting, white-balance gain clamping |
| `DeviceCatalogTests` | zoom labels from switch-over factors (3×, 4×, 5×, dual-wide, dual), the FOV heuristic, button text |
| `CaptureEngineTests` | 100 commands → 1 lock; a 120 Hz drag → no more than one lock per frame; EV ignored in manual; tap metering ignored in manual; clamping; lens-switch re-apply and clamp; MF kept across a switch; lock-failure retry and drop |
| `PhotoCaptureProcessorTests` | one item with both resources; HEIF-only; save failure keeps files; capture failure; partial captures; finish reported once; processor released on success and on error; develop hook |
| `CaptureFileStoreTests` | pending round trip, orphan cleanup, Documents export |
| `RotationTests` | glyph angles for all four orientations, shortest-path animation, quarter turns, buffer mapping (and its inverse), gravity roll and pitch |
| `GeometryAndPolicyTests` | aspect fit, tap normalisation, storage thresholds, histogram normalisation and change detection |

Run with **Product › Test** (⌘U) on the iPhone or a simulator. The camera does not start while tests run.

## 3. On-device checklist (iPhone 18 Pro Max) — fill in the numbers
| # | Check | Target | Result |
|---|-------|--------|--------|
| 1 | Instruments **Animation Hitches**, 30 s SS-slider drag in FOCUS (peaking on) and MANUAL | hitch ratio < 1 ms/s; UI at 120 fps (debug HUD shows `ui`) | |
| 2 | 50 consecutive RAW+HEIF shots | memory back within ±30 MB; 0 `PhotoCaptureProcessor` / `PhotoCaptureDelegate` in Memory Graph | |
| 3 | Press → `willCapturePhoto` latency (Console, category `CaptureEngine`; HUD shows `lag`) | HEIF < 100 ms; record RAW+HEIF | |
| 4 | One Photos item per press with the RAW badge; DNG opens in Lightroom | exactly 1 | |
| 5 | Portrait, landscape-left, landscape-right, upside-down shots | all saved upright | |
| 6 | Tap-to-focus in the four corners and the centre | box and focus land where tapped | |
| 7 | 20 fast lens switches (0.5 ⇄ 1 ⇄ tele, and front) | no black frame, no crash | |
| 8 | Phone call during preview; Control Centre; Split View on iPad (if used) | overlay with reason, clean recovery | |

### Open items from spec §14 (record what you find)
- ZSL / responsive capture with ProRAW: the engine logs `proRAW= zsl= responsive= fast=` for each lens at configuration time.
- Highest feed frame rate of the ProRAW format: the debug HUD's `feed` value. If 60 fps turns ProRAW off, the engine falls back to the default rate and logs it.
- Whether the zoom labels from `.builtInTripleCamera` match Apple's Camera app.

## 4. Where the code differs from the spec (and why)
1. **Video data output is not rotated.** The spec rotates it to the preview angle. Instead, the kernels map each overlay pixel into the unrotated buffer (`RotationMath.bufferPoint`, mirrored in `Shaders.metal`). Overlays still line up exactly, and the system doesn't have to rotate a 12 MP buffer every frame.
2. **Current exposure values.** `AVCaptureDevice.currentISO` / `exposureDurationCurrent` don't exist. The real properties, `iso` and `exposureDuration`, are used.
3. **Swift version.** Xcode's `SWIFT_VERSION` accepts language modes (4, 4.2, 5, 6), so "5.9" would not build. The project uses Swift 5 language mode (any Swift 5.9+ compiler) with `SWIFT_STRICT_CONCURRENCY = targeted`.
4. **Format choice.** `.photo` is Apple's ProRAW-capable 48 MP format. The engine keeps it, raises the frame rate to the format's maximum (60 fps cap, 30 at critical thermal), and restores the default rate if that turns ProRAW off. It doesn't iterate formats, because formats don't expose ProRAW support before they are active.
5. **Glyph rotation source.** Glyphs rotate from `UIDevice` orientation, which behaves the same for every lens, including the mirrored front camera. The rotation coordinator still drives the preview and capture angles.
6. **Failed saves are never deleted.** The spec clears temp files "at the next launch". Instead, pending shots are retried at launch and kept until they save. Only crash leftovers (no manifest, older than 10 minutes) are deleted.
7. **Tap-to-focus** uses continuous AF at the tapped point and returns to the centre on `subjectAreaDidChange`. In MANUAL exposure it moves focus only (F7).
8. **Level line** is computed from gravity in the screen plane. The old `attitude.roll` measured the wrong axis.
9. **EV slider** covers ±3 EV in 1/3 steps (the range Slice 2 specifies) rather than the device's ±8.
10. **Readouts** show the live auto ISO and shutter values in AUTO, and the set values in MANUAL.
11. **Engine coalescing tests** target `DeviceController`, the part of the engine that owns coalescing and the exposure rules, so they run without a camera.
