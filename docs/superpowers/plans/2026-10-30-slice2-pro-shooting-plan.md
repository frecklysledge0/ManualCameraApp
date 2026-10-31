# Slice 2 — Pro Shooting (Alpha-inspired): Implementation Plan and Record

**Spec:** `../specs/2026-10-30-slice2-pro-shooting-design.md` · **Depends on:** Slice 1 · **Status:** Implemented, waiting for an Xcode build and on-device verification

## 1. Decisions taken for the spec's [decide] items
| Item | Decision |
|------|----------|
| Fn bar | 7 tiles (MODE, F, SS, ISO, EV, WB, FOCUS) plus `Fn`. AUTO is shown in the accent colour. On fixed-aperture lenses the F tile is dimmed and shows the fixed ƒ-number. |
| Aperture "fine" mode | **Not built.** The spec builds it only if on-device testing shows `setExposureModeCustom` accepts apertures between the recommended stops. The dial snaps to `recommendedLensApertureStops`. |
| Peaking default colour | Cinnabar, as recommended. Red, Yellow, White and Blue are in the Fn sheet. |

## 2. What was built
- **Theme system** (`UI/Theme/CameraTheme.swift`): tokens plus component styles (`DialStyle`, `TileStyle`, `BadgeStyle`, `ShutterButtonStyle`, `TelemetryStyle`), injected with `.environment(\.cameraTheme, …)`. `CameraTheme.alpha` holds the Slice 2 tokens. `Branding.swift` holds every user-facing product name.
- **Layout** (`UI/CameraView.swift`): telemetry strip, then the 3:4 viewfinder, then the dial tray, the Fn bar and the shutter row. On shorter screens the viewfinder gets narrower so controls never cover it.
- **Dial** (`UI/Components/DialView.swift`):
  - The tick strip is drawn once in an `Equatable` `Canvas` and only translated while turning.
  - Drags move it 1:1. A fling decelerates at 120 Hz and snaps to a detent.
  - Every crossing gives a `detent` haptic. The ends give a rubber band and a `limit` haptic.
  - Double-tap returns to AUTO. VoiceOver can adjust it one detent at a time.
  - The Slice 3 rotary face is already wired to `DialStyle.rotary`.
- **P/A/S/M** (`Capture/ExposureProgram.swift`):
  - `ExposureRules.transition` locks the live values on every mode change.
  - `ExposureRules.plan` turns a mode into a device command.
  - On iOS 27 with priority support the hardware handles A/S. Otherwise S (and Auto ISO in M) runs the 15 Hz auto-ISO loop in `CaptureEngine` (`ExposureLoopMath`, gain 0.6, 1/12 EV deadband). The loop estimates the wanted ISO from the ISO the meter actually measured, so a frame of latency causes no overshoot.
- **Variable aperture** (`Capture/ApertureSupport.swift`):
  - It is the only file that uses the iOS 27 API, behind the `IOS27_APERTURE_API` compilation condition (set by default) and `#available(iOS 27, *)`.
  - API names follow the public iOS 27 SDK usage: `minLensAperture`, `maxLensAperture`, `recommendedLensApertureStops`, `supportsExposureModeCustom(lensAperture:duration:iso:)`, `AVCaptureDevice.autoExposureDuration` / `autoISO`, and `setExposureModeCustom(lensAperture:duration:iso:completionHandler:)`.
  - P uses `continuousAutoExposure`, so no aperture-auto constant is needed. A `DIFF` badge shows at ƒ/4. While the iris moves, the readiness coordinator holds the shutter.
- **Focus** (`Capture/FocusMath.swift`, `UI/Components/MFWheel.swift`):
  - **AF-S:** the tap focuses once. The frame turns to the accent colour and gives a `focusLock` haptic when `isAdjustingFocus` goes false. KVO feeds this, with a 0.5 s fallback for a lens that is already sharp.
  - **AF-C:** a tap moves the point of interest.
  - **MF wheel:** the gain is velocity-dependent (0.0005 to 0.01 per pt on a smoothed log curve), with half gain near ∞. A tick fires every 1/50 of travel, and a bar shows MFD ←→ ∞.
  - **Focus snap:** `sharpnessKernel` measures the edge energy in the focus ROI at native resolution. `SharpnessPeakDetector` fires `focusSnap` and flashes peaking once when the pull passes the peak.
- **Peaking v2 and zebras** run in one overlay pass (`overlayKernel`), drawn at about half screen resolution, which gives the edges their light dilation:
  - peaking has Low/Mid/High thresholds and 5 colours, on in MF and opt-in in AF
  - zebras are animated 45° stripes at 70/80/90/95/100+
- **Loupe** (`loupeKernel`):
  - It renders from the native-resolution video frame into a picture-in-picture panel at the top-right, centred on the last focus point. It opens when you touch the MF wheel and closes 0.6 s after release.
  - Default is 4×. A tap switches to 8× with nearest-neighbour sampling, so you see real pixels. 8× is only offered when the native frame is wider than 1920 px.
- **Telemetry:**
  - Histogram v2: RGB or luma, with clip markers above 0.5% in the end bins. Tap to expand it across the strip.
  - Two-axis level from gravity, with 0.5° in / 0.8° out hysteresis and one `level` haptic on arriving. An optional horizon line can show over the viewfinder.
  - Shots left: free space ÷ a running average of real shot sizes per format.
- **Haptics added:** `focusLock`, `focusSnap`, `level`, `modeChange`, plus a very light `focusTick` for the wheel. The Fn sheet has haptics on/off and an intensity setting (0.5–1.0).
- **Persistence:** a `Codable` `ShootingProfile` in `UserDefaults` holds each mode's values, the lens kind, focus mode, WB and tint, overlays, RAW, haptics and theme. Decoding is lenient, so later slices can add fields without wiping settings. The Slice 1 RAW toggle carries over.
- **Accessibility:** every tile and dial has a VoiceOver label and value, and swiping up or down moves one detent. Labels honour Bold Text. Reduce Motion swaps springs for fades and disables flings.

## 3. Behaviour details worth knowing
- **Turning a dial takes control of that parameter.** The SS dial in P switches to S, and in A switches to M. The F dial in P switches to A, and in S switches to M. The ISO dial outside M switches to M at the current values.
- **Long-press returns a tile to AUTO:**
  - MODE → P
  - SS → P (from S), or → A from M (P if A isn't available)
  - F → P (from A), or → S from M
  - ISO → Auto ISO (in M); EV → 0; WB → AWB; FOCUS → AF-C
- **Closing the tray.** Tap the same tile, tap the viewfinder (that tap doesn't focus) or swipe the tray down. When the tray is closed, its space shows the status banners.
- **Fn sheet.** The Edition toggle is shown disabled until Slice 3.

## 4. Where the code differs from the spec (and why)
1. **MF across lenses.** Slice 1 deferred a "distance-based" MF hand-over to Slice 2. AVFoundation publishes no lens-position-to-distance calibration (only `minimumFocusDistance`), so a reliable mapping isn't possible. MF keeps the raw lens position across a switch, and AF modes return to AF.
2. **Expanded histogram.** It replaces the telemetry strip while open. It isn't drawn over the viewfinder, so the image stays uncovered.
3. **Level haptic** fires when *roll* arrives at level. Pitch is shown with its own hysteresis but has no haptic, because pitch is rarely level when shooting up or down.
4. **Screen flash.** A brief black blink (a shutter blackout) replaces the white flash.

## 5. Unit tests added (`ProShootingTests`)
- mode transitions and plans
- auto-ISO loop convergence (100→800, 3200→100 and 50→6000 ISO all reach 0.1 EV within 1 s without overshoot)
- the MF gain curve (monotonic and bounded) and the extra resolution near ∞
- focus-snap traces (single peak, noise, two peaks, reset)
- level hysteresis
- WB table, presets and gain clamping
- aperture formatting and full-stop detection
- `ShootingProfile` round-trip, missing keys and `UserDefaults` persistence
- priority exposure in `DeviceController`: clamping, bias, and metering ignored when fully manual

## 6. On-device checklist (iPhone 18 Pro Max)
| # | Check | Target | Result |
|---|-------|--------|--------|
| 1 | Telemetry, peaking, zebras and loupe all on; drag dials (Instruments Animation Hitches) | 120 fps, hitch ratio < 1 ms/s | |
| 2 | Each aperture stop applies; the shutter waits while the iris moves | `limit` haptic when pressed mid-move | |
| 3 | A / S / M against a grey card vs P | within ±1/3 stop | |
| 4 | Loupe 8× shows real pixel detail | no blur from upscaling | |
| 5 | Level on a known-level surface | reads 0.0° ±0.3° | |
| 6 | Zebras at 100+ match the histogram's highlight clip marker | same areas | |
| 7 | S mode on an older iPhone (emulated loop) | ISO settles in < 1 s, no pumping | |
| 8 | Kill and relaunch | mode, values, lens, focus mode and overlays restored | |

### Open items from spec §13 (record what you find)
- Whether intermediate apertures are accepted. This decides fine mode.
- `supportsExposureModeCustom` for each priority combination on the 18 Pro Max. `ApertureSupport.capability` probes A, S and M aperture support per lens.
- Native video dimensions of the ProRAW format. The pipeline reports them, and they decide whether 8× is offered.
- **If the build fails in `ApertureSupport.swift`** (an SDK name differs), remove `IOS27_APERTURE_API` from *Build Settings › Active Compilation Conditions*. Everything else then builds, with S emulated and the F tile read-only.
