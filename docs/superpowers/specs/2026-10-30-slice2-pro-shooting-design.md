# Slice 2 — Pro Shooting (Alpha-inspired): Design Spec

**Date:** 2026-10-30 · **Status:** Draft, awaiting Rohit's review · **Depends on:** Slice 1 · **Roadmap:** `2026-10-30-camera-roadmap.md`

> Rohit has not yet walked through the decisions in this spec. Items marked **[decide]** are my recommendations and need a yes or a change.

## 1. Goal
Replace the stock UI with a dark, thumb-friendly pro interface inspired by Sony Alpha bodies. It has:
- Cinnabar `#FF5500` accents and monospace telemetry.
- A Quick Fn bar with tap-to-slide dials.
- True P/A/S/M exposure modes.
- Optical tools: a manual-focus wheel, focus peaking, a loupe, and variable aperture on iPhone 18 Pro.
- Live telemetry: histogram, two-axis level and zebras.

The viewfinder image is never covered by controls.

## 2. Scope
**In:** the theme system, the Alpha-inspired theme, the new layout, the Fn bar and Fn sheet, the dial component, P/A/S/M, EV and M.M. metering, the WB system, aperture control, AF-S/AF-C/MF, the MF wheel, focus peaking v2, the loupe, zebras, the histogram v2, the two-axis level, extra haptics, settings persistence, and accessibility.

**Out:** the Edition theme, framing crops, the colour pipeline, sounds (all Slice 3), video, and flash.

## 3. Theme system (also the foundation for Slice 3)
- `CameraTheme` is a struct of tokens (colours, fonts, metrics, motion) plus **component styles**: `DialStyle`, `TileStyle`, `BadgeStyle`, `ShutterButtonStyle`, `TelemetryStyle`.
- It is injected with `.environment(\.cameraTheme, …)`, and components render only through their style. In Slice 3 the Edition replaces the theme and the styles, not the screens.
- **Alpha-inspired tokens:**
  - bg `#000000`; surface `#111214`; surface-raised `#1B1C1F`
  - accent `#FF5500`; text `#FFFFFF` at 92%; secondary 60%; hairline `#FFFFFF` at 14%
  - warning `#FFC400`; clip `#FF3B30`
- **Fonts:** telemetry in SF Mono Medium, 13–15 pt, with tabular digits. Labels in SF Pro Text Semibold, 11 pt, uppercase, +4% tracking.

## 4. Layout (portrait, iPhone 18 Pro Max)
```
┌──────────────────────────────┐
│ TELEMETRY STRIP              │  mode badge · SS · F · ISO · EV/M.M. · WB · RAW · shots left
│ histogram (mini) · level     │  lives in the area above the 4:3 image
├──────────────────────────────┤
│                              │
│      4:3 VIEWFINDER          │  no controls drawn here, ever
│  (opt-in: grid, zebras,      │  overlays only when the user turns them on
│   peaking, level line,       │  loupe appears only while pulling focus
│   loupe while pulling focus) │
├──────────────────────────────┤
│ DIAL TRAY (slides up)        │  shown only when a tile is active
│ [MODE][F][SS][ISO][EV][WB][FOCUS] [Fn] │  Quick Fn bar
│ thumb    ◉ SHUTTER    lenses │
└──────────────────────────────┘
```
- **[decide]** There are 7 tiles plus `Fn`. Each tile shows its current value, with "AUTO" in accent when that parameter is automatic. The `F` tile shows a fixed `ƒ/x` (disabled) on lenses without a variable aperture.
- **Tap a tile:** the dial tray slides up (spring, 0.28 s). Tap the same tile, tap the viewfinder, or swipe down to dismiss. **Long-press a tile:** that parameter returns to AUTO.
- **`Fn` sheet** (secondary settings, half-height):
  - focus: AF-S/AF-C/MF
  - peaking: on in AF, colour, level
  - zebras: on, threshold
  - grid: off/thirds/square
  - level: on/off
  - histogram: RGB/luma
  - RAW toggle
  - haptics: on/off, intensity
  - Edition toggle placeholder (enabled in Slice 3)

## 5. Dial component
- A horizontal drum with tick marks. Major ticks are full stops with labels, minor ticks are 1/3 stops.
- Drags move it 1:1. A fling decelerates with physics and **snaps to a detent**, and every crossing fires a `detent` haptic. At a range end you feel a `limit` haptic and get a rubber-band.
- Double-tap the dial for AUTO.
- **Tables:**
  - **SS:** 1/3-stop series between the device's min and max duration (…1/8000 … 1/1000 … 1/125 … 1″ …), clamped to the device.
  - **ISO:** 1/3 stops (25, 32, 40, 50, 64, 80, 100…), clamped to `minISO…maxISO`.
  - **EV:** ±3 in 1/3 steps, clamped to the device bias range.
  - **WB:** AWB, Daylight 5500 K, Shade 7500 K, Cloudy 6500 K, Tungsten 3200 K, Fluorescent 4000 K, then Kelvin 2500–10000 K in 100 K steps, plus a tint sub-dial of ±150 in steps of 10. The old 3000–8000 K limit is removed, and gains are clamped to `[1, maxWhiteBalanceGain]`.
  - **F:** see §7.
- Rendering uses `Canvas` with ticks drawn once and translated, so it holds 120 Hz.

## 6. Exposure modes
| Mode | iOS 27 with aperture hardware | Earlier iOS or no aperture |
|------|------------------------------|----------------------------|
| **P** (program) | `continuousAutoExposure`, aperture Auto. EV = `exposureTargetBias`. | Same, without aperture. |
| **A** (aperture priority) | `setExposureModeCustom(lensAperture: f, duration: Auto, iso: Auto)`. Validate with `supportsExposureModeCustom`. | **Hidden.** |
| **S** (shutter priority) | `setExposureModeCustom(lensAperture: Auto/current, duration: s, iso: Auto)` when supported. | **Emulated:** a 15 Hz control loop on `sessionQueue` sets `iso = clamp(iso · 2^(-exposureTargetOffset))` with damping, so ISO tracks the meter. |
| **M** (manual) | All three set explicitly. **Auto ISO in M** (Sony-style) is available by long-pressing ISO, using the same loop or `iso: Auto`. | Same. |

- **EV:** in P/A/S, EV sets the bias. In M, the EV tile becomes **M.M.** (metered manual) and shows `exposureTargetOffset` as a live ±3 scale. In M with Auto ISO, EV biases the loop target.
- `photoQualityPrioritization` is `.speed` in A/S/M and `.balanced` in P (as in Slice 1).
- **Mode changes** lock the current auto values first so the image never jumps. The mode badge animates.

## 7. Variable aperture (iPhone 18 Pro, main camera, iOS 27)
- **Capability:** `#available(iOS 27, *)` and `activeFormat.minLensAperture < activeFormat.maxLensAperture`. Otherwise the F tile is read-only and shows `lensAperture`.
- **Dial:** snaps to `activeFormat.recommendedLensApertureStops` (expected: 1.48 / 1.8 / 2.8 / 4.0). **[decide]** A long-press on the F dial enables "fine" mode with 1/3-stop values between min and max, *only if* on-device testing shows `setExposureModeCustom` accepts values between the recommended stops. Otherwise fine mode is not built.
- **Iris motion:** while the iris is moving (between the call and the completion handler), the shutter is not ready. Readiness handles this, and the shutter gives a `limit` haptic if pressed. The F readout animates to the applied value.
- **In P mode** the aperture is Auto (`AVCaptureDevice.lensApertureAuto`), and the readout shows the live `lensAperture`.
- **Diffraction hint:** at ƒ/4.0, a small "DIFF" glyph sits next to the F value. It is informational only.

## 8. Focus
- **AF-S:** tap to focus once, then lock. Confirmation is the frame turning accent-coloured plus a `focusLock` haptic when `isAdjustingFocus` becomes false.
- **AF-C:** continuous. A tap moves the point of interest.
- **MF:** the FOCUS tile opens the **MF wheel** in the dial tray.
  - It maps finger travel to `lensPosition` with a **velocity-dependent gain**. Slow movement is fine (1 px ≈ 0.0005), fast movement is coarse (up to 0.01), through a smooth log curve. Extra resolution is given near infinity, where `lensPosition` changes are perceptually larger.
  - An indicator bar shows `MFD ←→ ∞` with the current position. Very light `detent` ticks fire every 1/50 of travel.
  - **Focus snap:** `FramePipeline` computes a sharpness metric (sum of edge energy in the focus ROI). When the metric passes a local maximum during a pull (it rises above a threshold, then drops), a `focusSnap` haptic fires and peaking flashes once.
  - Setting it uses `setFocusModeLocked(lensPosition:)` through engine coalescing.
- **Peaking v2:**
  - Luma Sobel at analysis resolution, a 3-level threshold (Low/Mid/High), and 1 px edges with light dilation.
  - Colours: Cinnabar, Red, Yellow, White, Blue. The default is Cinnabar. **[decide]** Default to Red if Cinnabar clashes with the accent colour.
  - On automatically in MF, opt-in in AF.
- **Loupe:**
  - Opens automatically when a finger touches down on the MF wheel and closes 0.6 s after release.
  - A picture-in-picture panel at the top-right of the viewfinder (the only temporary overlay over the image), centred on the focus point (last tap, otherwise the centre).
  - Defaults to 4×. Tap the loupe for 8×.
  - Rendered by Metal from the **native-resolution** video frame, so 8× shows real pixels. The video data output therefore delivers the format's native dimensions, and the pipeline downsamples on the GPU for analysis. If native video is ≤1920 px wide on the device, 8× is disabled to avoid fake upscaling.

## 9. Telemetry
- **Histogram v2:** 256-bin RGB or luma on a 256×192 GPU downsample at ≤30 Hz. Clip markers light up when more than 0.5% of pixels fall in the top or bottom bin. Mini version in the strip, with a tap to expand.
- **Two-axis level:**
  - Roll and pitch from `CMDeviceMotion.gravity`.
  - Sony-style horizon bar for roll plus a pitch bubble.
  - Both turn accent-coloured within ±0.5°, with 0.3° hysteresis, and a single `level` haptic fires on arriving at level.
  - Shown in the strip. An optional thin horizon line can appear over the viewfinder.
- **Zebras:** a GPU shader on luma draws animated 45° stripes where luma ≥ threshold. Thresholds: 70 / 80 / 90 / 95 / 100+; the default is 95. Composited in the same Metal overlay pass as peaking, so it is one layer and one draw.
- **Shots left:** free space ÷ the average size per shot for the current format. Recomputed after each capture.
- All telemetry views are leaf views reading `LiveTelemetry`. None of them re-renders `CameraView`.

## 10. Haptics added
| Event | Pattern |
|------|---------|
| `focusLock` | (0.6, 0.6) |
| `focusSnap` | Two quick transients (0.5, 1.0) 18 ms apart |
| `level` | (0.4, 0.5) |
| `modeChange` | (0.7, 0.4) |

The Fn sheet adds a haptics on/off switch and an intensity setting (0.5–1.0 scale).

## 11. Persistence and accessibility
- Mode, per-mode values, lens, focus mode, overlay toggles and theme selection are restored on launch. A `Codable` `ShootingProfile` is stored in `UserDefaults`.
- VoiceOver labels and adjustable actions on every tile and dial (swipe up or down = one detent).
- The telemetry font size is fixed, but labels honour Bold Text. Reduce Motion replaces springs with fades.

## 12. Testing and verification
**Unit:**
- dial tables and clamping
- the S/Auto-ISO control loop (simulated meter converges within 0.1 EV in under 1 s with no oscillation)
- mode transition rules
- MF gain curve monotonicity
- the sharpness-peak detector on recorded metric traces
- WB presets → gains clamping
- `ShootingProfile` round-trip

**On-device:**
- 120 fps UI with telemetry, peaking, zebras and the loupe all on (hitch ratio < 1 ms/s)
- aperture stops apply and the shutter waits for the iris
- A/S/M expose correctly against a grey card (within ±1/3 stop of P)
- the loupe at 8× shows real pixel detail
- the level reads 0.0° on a known-level surface (±0.3°)
- zebras match the histogram clip markers

## 13. Open items to verify on device
- Whether intermediate apertures are accepted (this decides fine mode).
- `supportsExposureModeCustom` for each priority combination on the 18 Pro Max.
- The native video dimensions of ProRAW formats (this decides whether the 8× loupe is possible).
