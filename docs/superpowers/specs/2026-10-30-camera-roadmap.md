# ManualCameraApp — Upgrade Roadmap

**Date:** 2026-10-30 · **Owner:** Rohit · **Status:** Draft, awaiting review

## Vision
Make ManualCameraApp an ultra-smooth, professional camera that feels like physical hardware, with a Sony Alpha–inspired pro interface by default and a one-tap Hasselblad-inspired "Edition" mode that changes both the UI and the colour of the photos.

## Decisions made so far
- **Order: shippable slices.** Each slice leaves a better, usable app behind it.
- **Devices:** iPhone 18 Pro Max is the primary test device. Minimum deployment target is **iOS 17**. Hardware-specific features (variable aperture, iOS 27 priority modes) appear only when the device and OS support them.
- **Capture output:** one shutter press saves **one Photos item containing ProRAW (DNG) + HEIF**. A RAW toggle switches to HEIF-only for fast shooting.
- **Architecture:** approach **B**. Restructure the camera core (capture engine, separate `@Observable` state objects, a Metal frame pipeline, a haptics engine) and keep the existing UI until Slice 2 replaces it.

## Slices (review and build in this order)
| # | Slice | Spec | Depends on |
|---|-------|------|-----------|
| 1 | **Stabilize**: bug fixes, 120 Hz UI, capture pipeline, rotation, lens switching, Core Haptics | `2026-10-30-slice1-stabilize-design.md` | — |
| 2 | **Pro Shooting (Alpha-inspired)**: theme system, Fn bar, dials, P/A/S/M, telemetry, MF wheel, peaking, loupe, aperture | `2026-10-30-slice2-pro-shooting-design.md` | 1 |
| 3 | **Medium Format Edition (Hasselblad-inspired)**: Edition theme, 1:1 and 65:24 framing, colour and grain pipeline, leaf-shutter sound | `2026-10-30-slice3-medium-format-edition-design.md` | 1, 2 |

Each slice goes through its own cycle: spec review, then implementation plan, then build, then on-device verification. A slice's plan is written only after that slice's spec is approved.

## Facts the specs rely on (verified 2026-10-30)
- The iPhone 18 Pro main camera has a variable aperture from ƒ/1.48 to ƒ/4.0. Apple's Camera app offers four stops: ƒ/1.48, ƒ/1.8, ƒ/2.8, ƒ/4.0.
- iOS 27 AVFoundation adds `setExposureModeCustom(lensAperture:duration:iso:)`, `Format.minLensAperture` / `maxLensAperture` / `defaultLensAperture` / `recommendedLensApertureStops`, `supportsExposureModeCustom(lensAperture:duration:iso:)`, and per-parameter `…Auto` constants (priority modes).
- Locked manual exposure is honoured for still capture only when `photoQualityPrioritization == .speed`.

## Naming and trademarks
"Sony", "Alpha", "Hasselblad" and "HNCS / Hasselblad Natural Colour Solution" are trademarks of their owners, and HNCS is proprietary. In code and documents this project uses its own names: **Alpha-inspired theme**, **Medium Format Edition**, and **MF Natural Colour** (an original look, not a reproduction of HNCS). User-facing labels come from one branding file, so a personal build can say whatever Rohit likes. Any App Store build must use original names and an original or licensed shutter sound.
