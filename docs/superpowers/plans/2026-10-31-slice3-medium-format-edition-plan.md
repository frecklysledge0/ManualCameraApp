# Slice 3 — Medium Format Edition: Implementation Plan and Record

**Spec:** `../specs/2026-10-30-slice3-medium-format-edition-design.md` · **Depends on:** Slices 1–2 · **Status:** Implemented, waiting for an Xcode build and on-device verification. The golden reference set still has to be supplied (see §5).

This slice also carries the UI and capture fixes reported after Slice 2: duplicated read-outs, RAW saving as HEIF only, Camera Control as a shutter, a Sony-style centre focus frame and general layout polish.

## 1. Decisions taken for the spec's [decide] items
| Item | Decision |
|------|----------|
| Name | `Branding.editionName` = "Medium Format Edition", look = "MF Natural Colour". A personal build can rename both in `Branding.swift`; nothing else hard-codes them. |
| Kept RAW and framing | The DNG always stays full-frame. Only the developed HEIF is cropped to 1:1 or XPAN, so the crop can be changed later in any editor. |
| Edition develop source | Always RAW when the lens has a RAW format (the engine captures `.raw` for the Edition whatever the format setting). The chosen format decides only whether the DNG is kept beside the developed HEIF. Without RAW the look is applied to Apple's HEIF (colour and grain apply, Apple's sharpening can't be undone). |
| Grain default | Fine. Off / Fine / Medium in the Fn sheet. |
| Shutter sound default | Low, through an `.ambient` audio session, so the silent switch mutes it and music keeps playing. |
| Preview grain | Off by default (a static half-strength texture when on, so the viewfinder never shimmers). |
| Golden set | Not generated. The photographer supplies approved DNG + PNG pairs; until then `GoldenImageTests` is skipped. |

## 2. What was built
- **Look authoring** (`tools/look/`):
  - `look.json` is the single source of the look: CIRAWFilter develop values, the shaper, the hue bands, skin protection, the tone curve and grain.
  - `make_look.py` (numpy) designs colour and tone in OKLCh. It writes a 65³ `.cube` (`Resources/MFNaturalColour.cube`) in a cube-root shaper space, `s = (linear P3 / 8)^(1/3)`, so highlights up to 8× diffuse white keep detail. It also writes `Resources/look.json` and the generated `Sources/Capture/Edition/LookConstants.swift`, all stamped with the SHA-256 of `look.json`.
  - `make_assets.py` makes the 64×64 void-and-cluster blue-noise tile and the 78 ms, 48 kHz leaf-shutter sound.
- **Develop** (`Capture/Edition/EditionDeveloper.swift`):
  - `CIRAWFilter` runs with no sharpening, reduced local tone mapping, a gentle boost and low luminance noise reduction. Each property is set only when the RAW supports it.
  - Then the framing crop, then `MFLookKernel` (a `CIImageProcessorKernel`, so Core Image tiles 48 MP images), which runs `lookStillKernel`: LUT + three-octave, luminance-weighted, monochromatic grain with a per-photo seed (FNV-1a of the capture ID).
  - Output is 10-bit HEIF in Display P3 (8-bit HEIF fallback), with camera metadata kept, orientation reset to up and the Software tag set.
  - Develops run on one serial queue, so a burst never holds two 48 MP develops in memory. The shutter holds (with a `limit` haptic) while three shots wait.
- **Live look** (`Pipeline/EditionPreviewRenderer.swift`, `lookPreviewKernel`): every video frame goes through the same LUT and shared Metal functions into an opaque layer above the preview, which fades in over 0.35 s. BT.709 frames are converted to P3 first, so the preview matches the still.
- **Edition interface** (`CameraTheme.edition`): near-black, monochrome, emphasis by inversion; large light SS/F/ISO/EV read-outs in the strip with a luma outline histogram and a hairline level; five tiles (MODE, F, SS, ISO, EV) that show only their names; the arc dial; a flat shutter disc; WB and focus mode in the Fn sheet. The theme cross-dissolves in 0.35 s.
- **Framing**: 4:3, 1:1 and XPAN (65:24) mattes over the viewfinder (88% black, hairline edge, animated), using the same `FramingMath` as the develop. Tap the framing badge in the strip to cycle.
- **Feedback**: a two-part `leafShutter` haptic, an `edition` haptic for the toggle, the leaf-shutter sound at `willBeginCapture`, and an instant viewfinder thumbnail that the developed one replaces.

## 3. Fixes to the Slice 2 interface and capture
- **Each value is shown once.** The Pro strip is a status header (mode, AF, format, aspect, shots left, battery, histogram, level); exposure values live only on the Fn bar. In the Edition they live only in the strip (`CameraTheme.tilesShowValues`). The system status bar is hidden because the strip already shows battery.
- **RAW.** `CaptureFormat` (HEIF / RAW / RAW+HEIF) replaces the RAW toggle, and RAW is the default:
  - RAW: the DNG is the Photos item, so Photos shows it as RAW / ProRAW.
  - RAW+HEIF: the HEIF is the item and the DNG is paired as its alternate (Apple's documented pairing). An embedded preview gives RAW-only shots a thumbnail.
  - After the session commits, the engine checks that ProRAW is really enabled and re-configures if not.
  - Old profiles migrate: RAW on → RAW, RAW off → HEIF.
- **Camera Control.** `AVCaptureEventInteraction` takes the photo on release of Camera Control (iPhone 16 and later) and of the volume buttons.
- **Focus frame.** The frame sits at the centre, like an Alpha body's centre area. A tap moves it and it stays there (subject-area recentring is off). A long-press returns it to the centre. White while searching, green when AF-S locks or AF-C settles, hidden in MF.
- **Layout.** The viewfinder is full-width whenever the screen fits it; the dial tray rises over its lower edge only while open. The focus tray no longer overflows (92 pt tray, compact wheel). The dial's index and AUTO label no longer cover the values. Colours are split into `selection` (orange) and `confirmation` (green). The debug HUD is off unless switched on in the Fn sheet (debug builds only).

## 4. Tests added
`EditionTests`: crop maths (6048², 8064×2977, portrait, bounds), grain scale and ISO boost, seed and octave determinism, the `.cube` parser, the bundled LUT and `look.json` hash against `LookConstants`, the Swift/Metal `LookParams` layout, half-float packing, CIEDE2000 against the Sharma test pairs, theme rules, Edition settings persistence and output metadata. `GoldenImageTests`: mean ΔE00 < 1.0 and p99 < 3.0 against supplied references (skipped without them). `ProShootingTests` covers the format migration.

## 5. On-device checks still needed
1. RAW: shoot in RAW and RAW+HEIF; in Photos, the RAW badge appears and *Info* shows DNG / ProRAW.
2. Camera Control click and volume buttons take one photo each.
3. Focus frame: tap moves it, it stays, long-press re-centres, green on lock, hidden in MF.
4. Edition: the preview look matches the developed photo; 1:1 and XPAN crops match the mattes; the shutter sound is muted by the silent switch; a five-shot burst saves five photos.
5. Supply the golden set (`Tests/Golden/<name>.dng` + `<name>.png`) to activate `GoldenImageTests`.
