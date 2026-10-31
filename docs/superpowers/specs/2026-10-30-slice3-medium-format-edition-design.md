# Slice 3 — Medium Format Edition (Hasselblad-inspired): Design Spec

**Date:** 2026-10-30 · **Status:** Draft, awaiting Rohit's review · **Depends on:** Slices 1 and 2 · **Roadmap:** `2026-10-30-camera-roadmap.md`

> Rohit has not yet walked through the decisions in this spec. Items marked **[decide]** are my recommendations and need a yes or a change.

## 1. Goal
One tap turns the app into a calm, minimalist medium-format camera inspired by the Hasselblad X2D 100C. The Edition has:
- Its own UI.
- A leaf-shutter sound.
- 1:1 and 65:24 framing.
- **MF Natural Colour**, an original colour science with smooth highlight roll-off, deep shadows that keep their detail, organic grain, warm and true skin tones, and no artificial sharpening.

**Naming:** "Hasselblad" and "HNCS" are trademarks, and HNCS is proprietary. This spec builds an **original** look *inspired by* medium-format rendering. All user-facing names live in `Branding.swift`. **[decide]** A personal build can label the toggle "Hasselblad Mode", but App Store builds must use "Medium Format Edition".

## 2. Scope
**In:** the Edition toggle and transition, the Edition theme and component styles, the framing modes and mattes, the RAW-develop colour pipeline, grain, a Metal preview of the look, the leaf-shutter sound, Edition haptics, the look-authoring tool, and golden-image tests.

**Out:** user-editable looks or LUT import, film-simulation variants, video.

## 3. Toggle and transition
- The Edition toggle lives in the `Fn` sheet and in Settings, and is persisted. Turning it on:
  1. switches `cameraTheme` to `.edition`
  2. switches the preview renderer to the Metal look preview (§7)
  3. switches the capture path to the Edition develop (§6)
  4. enables the framing control
- **Transition:** a 0.35 s cross-dissolve of the HUD plus a soft `edition` haptic. The viewfinder never goes black, because the Metal preview takes over on the next frame and the old layer fades out.

## 4. Edition UI (theme and component styles from Slice 2)
- **Tokens:**
  - bg `#0A0A0A`; surface `#141414`; text `#F2F2F2`; secondary 55%
  - no colour accent: emphasis is shown by **inversion** (black on white)
  - hairline `#FFFFFF` at 18%
- **Type:** large, clean sans. Primary readouts (shutter, aperture, ISO, EV) in SF Pro Display Light 30–34 pt with tabular digits. Labels in SF Pro Text Regular 11 pt with +8% tracking.
- **Badges:** high-contrast monochrome rounded rectangles (radius 4), for example `RAW`, `1:1`, `XPAN`, `A`, `M`.
- **Dials:** `RotaryDialStyle` replaces the drum. It is a semicircular arc dial above the shutter, using the same detents, tables and haptics as Slice 2. Only the rendering differs.
- **Simplified HUD:** the strip shows only SS, F, ISO and EV, plus a minimal luma histogram (thin outline) and a hairline level. The Fn bar condenses to 5 tiles: MODE, F, SS, ISO, EV. WB and FOCUS move to the Fn sheet.
- **Shutter button:** a flat white disc with a thin ring. It presses down with a 0.12 s ease.

## 5. Framing
| Mode | Ratio | Output (from 8064×6048) |
|------|-------|------------------------|
| Native | 4:3 | 8064×6048 |
| Square (6×6) | 1:1 | 6048×6048, centred |
| XPAN panoramic | 65:24 | 8064×2977, centred |

- The **preview** gets matte bars at 88% black with a 1 px hairline frame at the crop edge. Changing ratio animates the matte (0.3 s).
- **Output:** the developed HEIF is cropped. **[decide]** The DNG in the same Photos item stays full-frame and uncropped, so no data is lost. Writing a DNG `DefaultCrop` is out of scope.
- Framing options are available only in the Edition.

## 6. MF Natural Colour pipeline (stills)
**Source:** in the Edition, every capture includes RAW internally (ProRAW, else Bayer RAW). If no RAW is available, the look is applied to the processed HEIF instead. This is marked as a fallback, because Apple's built-in sharpening cannot be undone there.

**Develop with `CIRAWFilter` (Core Image, Metal-backed, `RGBAh` linear Display P3 working space):**
- `sharpnessAmount` ≈ 0 (no over-sharpening)
- `localToneMapAmount` lowered (≈0.3, tuned) to avoid the "HDR phone look"
- `boostAmount` tuned for a gentle base curve
- luminance noise reduction kept low, so the texture feels like film; colour noise reduction at the default

**Look stages, in order:**
1. **Colour rendering:** a 65³ 3D LUT applied in a log-encoded shaper space (`CIColorCubeWithColorSpace`).
   - Reds lean slightly toward orange.
   - Greens are slightly desaturated toward olive.
   - Blues shift slightly toward cyan with a little less saturation.
   - Overall saturation is about −5%.
2. **Skin protection,** baked into the same LUT and built in OKLCh. In the skin hue band (≈20–60°), hue is pulled toward ≈45° with a soft weight, chroma spikes are compressed, and magenta casts are suppressed. The result is warm and true, never orange.
3. **Tone curve (filmic),** applied to luminance with chroma preserved, so highlights do not shift hue.
   - A long, soft shoulder starting about 1.5 stops below clip gives the smooth highlight roll-off.
   - Mid contrast is mild.
   - A dense toe gives rich shadows without crushing anything above ~1% reflectance.
   - Highlights desaturate naturally near white.
4. **Grain:** monochromatic, luminance-dependent grain.
   - A blue-noise texture is tiled at 3 octaves, and grain size is scaled to output height so a 6×6 crop matches a 4:3 frame.
   - Amplitude peaks in the midtones and falls off in highlights and deep shadows. It rises slightly with ISO.
   - The seed is deterministic per photo. Settings: Off / Fine / Medium (default Fine).
5. **No sharpening stage.**

**Output:** 10-bit HEIF in Display P3 with the look baked in. If RAW is on, the untouched DNG is added as `.alternatePhoto`. EXIF `Software` = `ManualCameraApp — MF Natural Colour`.

**Performance and memory:**
- Developing runs on a background queue with a `CIContext` (`cacheIntermediates = false`).
- Target: ≤ 1.5 s per 48 MP shot on A20 Pro. Peak memory ≤ 600 MB.
- Up to 3 shots can wait in the queue. After that, readiness holds the shutter.
- A thumbnail from the preview frame appears immediately, and the developed version replaces it when ready.

**Look authoring:** `Tools/look/make_look.py` turns `look.json` (all parameters) into `MFNaturalColour.cube`, which is committed and bundled. The same JSON drives the Metal preview shader's constants, so preview and still use identical numbers.

## 7. Live preview of the look
In the Edition, the viewfinder is drawn by a **Metal preview renderer** from video data output frames instead of `AVCaptureVideoPreviewLayer`. It applies the LUT and tone curve, with cheap static grain at 50% (optional).
- This adds about one frame of latency, which is acceptable in this calmer mode.
- The standard theme keeps the preview layer for the lowest latency.
- The preview is a close **approximation**: video frames are Apple-processed, not RAW. The target is an average ΔE2000 of 4 or less between the preview and the final still on the reference set.

## 8. Leaf-shutter sound
- An **original** asset, recorded from a real leaf shutter or synthesised. It is a short, soft double "tk-tk" of about 60–80 ms, with no mirror slap. Stored as 48 kHz CAF in the bundle.
- **Playback:** an `AVAudioEngine` with a pre-scheduled `AVAudioPlayerNode` buffer, triggered at `willBeginCaptureFor` for lowest latency.
- The audio session uses `.ambient` + `mixWithOthers`, so it respects the silent switch and doesn't interrupt music. Volume options in Settings: Off / Low / Medium.
- In regions where iOS forces the system shutter sound, that sound plays anyway. This is documented, not worked around.
- **Edition haptic:** `leafShutter` = (0.55, 0.35), then a transient at +28 ms (0.35, 0.8). It is softer than the standard shutter.

## 9. Testing and verification
- **Golden-image tests:** 12 reference DNGs cover different skin tones, a sunset with bright highlights, low-light shadows, foliage, blue sky, a neutral grey card, and a high-ISO scene. Rendered output must stay within an average ΔE2000 of 2 of the approved renders, and every change to `look.json` requires re-approving the contact sheet.
- **Unit:** framing crop math, LUT loading and colour space, the grain-size scaling formula, deterministic seed, and that `look.json` → preview constants matches the cube.
- **On-device:**
  - toggle round trip with no black frame and 120 Hz HUD
  - develop time and peak memory over 20 shots
  - preview-vs-still ΔE on the reference scenes
  - the sound plays within 20 ms of `willBeginCapture` and is silent with the silent switch on
  - XPAN and 1:1 outputs have the exact pixel dimensions
- **Visual review:** Rohit approves a side-by-side contact sheet (standard vs MF Natural Colour) before the look is frozen.

## 10. Open items
- How much `CIRAWFilter` local tone mapping can be reduced on ProRAW before shadows become noisy. Tune this on the reference set.
- Recording or synthesising the shutter sound. Rohit may want to record his own.
