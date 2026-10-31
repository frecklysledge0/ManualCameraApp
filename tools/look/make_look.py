#!/usr/bin/env python3
"""Builds the Edition's looks from look.json (Slice 3 §6 "Look authoring").

    python3 tools/look/make_look.py

Writes:
  Resources/MFNaturalColour.cube           65³ 3D LUT of the base look (cube-root shaper input)
  Resources/Looks/<id>.cube                 one LUT per extra look in look.json "looks"
  Resources/look.json                       the exact source, bundled for the tests
  Sources/Capture/Edition/LookConstants.swift   the same numbers for Swift / Metal

Every look is an original rendering built from the base look plus overrides (colour, tone,
white balance, monochrome mix, split toning, fade), so all looks share one tone and gamut model.

The LUT bakes, in order: colour rendering (hue/chroma moves in OKLCh), skin protection, and the
filmic tone curve applied to luminance with chroma preserved plus highlight desaturation. Grain is
not in the LUT (it depends on position); its parameters go to LookConstants.

Requires numpy.
"""

from __future__ import annotations

import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent / "look.json"

P3_TO_XYZ = np.array([
    [0.4865709, 0.2656677, 0.1982173],
    [0.2289746, 0.6917385, 0.0792869],
    [0.0000000, 0.0451134, 1.0439444],
])
XYZ_TO_P3 = np.linalg.inv(P3_TO_XYZ)
XYZ_TO_LMS = np.array([
    [0.8189330101, 0.3618667424, -0.1288597137],
    [0.0329845436, 0.9293118715, 0.0361456387],
    [0.0482003018, 0.2643662691, 0.6338517070],
])
LMS_TO_XYZ = np.linalg.inv(XYZ_TO_LMS)
LMS_TO_LAB = np.array([
    [0.2104542553, 0.7936177850, -0.0040720468],
    [1.9779984951, -2.4285922050, 0.4505937099],
    [0.0259040371, 0.7827717662, -0.8086757660],
])
LAB_TO_LMS = np.linalg.inv(LMS_TO_LAB)
LUMA = P3_TO_XYZ[1]


def p3_to_oklab(rgb: np.ndarray) -> np.ndarray:
    lms = rgb @ (XYZ_TO_LMS @ P3_TO_XYZ).T
    return np.cbrt(lms) @ LMS_TO_LAB.T


def oklab_to_p3(lab: np.ndarray) -> np.ndarray:
    lms = (lab @ LAB_TO_LMS.T) ** 3
    return lms @ (XYZ_TO_P3 @ LMS_TO_XYZ).T


def hue_distance(h: np.ndarray, center: float) -> np.ndarray:
    return (h - center + 180.0) % 360.0 - 180.0


def band(h: np.ndarray, center: float, width: float) -> np.ndarray:
    """Raised-cosine weight: 1 at the centre, 0 beyond ±width (smooth, so the LUT has no seams)."""
    d = np.abs(hue_distance(h, center))
    return np.where(d < width, 0.5 * (1.0 + np.cos(np.pi * d / width)), 0.0)


def smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def tone_curve(y: np.ndarray, tone: dict) -> np.ndarray:
    """Scene-linear luminance → display-linear: dense toe, mild mid contrast, long soft shoulder."""
    y = np.maximum(y, 0.0)
    toe = y * y / (y + tone["toe"])
    mid = tone["midGrey"]
    contrast = mid * np.power(np.maximum(toe, 1e-12) / mid, tone["midContrast"])
    s0 = tone["shoulderStart"]
    shoulder = s0 + (1.0 - s0) * (1.0 - np.exp(-(contrast - s0) / (1.0 - s0)))
    return np.where(contrast <= s0, contrast, shoulder)


def merged(base: dict, overrides: dict) -> dict:
    """Deep merge: dictionaries merge key by key, everything else replaces."""
    out = dict(base)
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merged(out[key], value)
        else:
            out[key] = value
    return out


def into_gamut(rgb: np.ndarray, luminance: np.ndarray) -> np.ndarray:
    """Pulls each colour towards its luminance until every channel is in [0, 1] (keeps hue)."""
    Yc = np.clip(luminance, 0.0, 1.0)[:, None]
    over = np.where(rgb > 1.0, (1.0 - Yc) / np.maximum(rgb - Yc, 1e-9), 1.0)
    under = np.where(rgb < 0.0, Yc / np.maximum(Yc - rgb, 1e-9), 1.0)
    t = np.clip(np.minimum(over.min(axis=1), under.min(axis=1)), 0.0, 1.0)[:, None]
    return np.clip(Yc + t * (rgb - Yc), 0.0, 1.0)


def render(linear: np.ndarray, look: dict) -> np.ndarray:
    """Applies colour rendering, skin protection and tone to linear Display P3 (N×3)."""
    colour = look["colour"]
    skin = look["skin"]
    tone = look["tone"]

    linear = np.maximum(linear, 0.0)
    if "whiteBalance" in look:
        # A gentle overall warm / cool cast, as camera-side gains.
        wb = look["whiteBalance"]
        linear = linear * np.array([wb.get("red", 1.0), wb.get("green", 1.0), wb.get("blue", 1.0)])

    lab = p3_to_oklab(linear)
    L = lab[:, 0]
    C = np.hypot(lab[:, 1], lab[:, 2])
    h = np.degrees(np.arctan2(lab[:, 2], lab[:, 1])) % 360.0

    # 1. Colour rendering.
    hue_shift = np.zeros_like(h)
    chroma_scale = np.ones_like(C)
    for key in ("reds", "greens", "blues"):
        b = colour[key]
        w = band(h, b["centerHue"], b["width"])
        hue_shift += w * b["hueShift"]
        chroma_scale *= 1.0 + w * (b["chroma"] - 1.0)
    h = h + hue_shift
    C = C * chroma_scale * colour["saturation"]

    # 2. Skin protection: warm and true, never orange or magenta.
    centre = 0.5 * (skin["bandStart"] + skin["bandEnd"])
    half = 0.5 * (skin["bandEnd"] - skin["bandStart"]) + 10.0
    lightness = smoothstep(skin["lightnessMin"] - 0.1, skin["lightnessMin"], L) * (1.0 - smoothstep(skin["lightnessMax"], skin["lightnessMax"] + 0.06, L))
    presence = smoothstep(0.015, 0.04, C) * lightness
    ws = band(h, centre, half) * presence
    h = h - ws * skin["pull"] * hue_distance(h, skin["targetHue"])
    knee = skin["chromaKnee"]
    C = np.where(C > knee, knee + (C - knee) * (1.0 - ws * skin["chromaCompression"]), C)
    wm = band(h, 8.0, 22.0) * presence
    h = h - wm * skin["magentaGuard"] * hue_distance(h, 25.0)

    hr = np.radians(h % 360.0)
    lab = np.stack([L, C * np.cos(hr), C * np.sin(hr)], axis=1)
    rgb = oklab_to_p3(lab)

    if "monochrome" in look:
        # Black and white through a colour filter: a weighted mix of the scene's channels.
        mix = np.array(look["monochrome"]["mix"], dtype=float)
        mono = np.maximum(np.maximum(linear, 0.0) @ (mix / mix.sum()), 0.0)
        rgb = np.repeat(mono[:, None], 3, axis=1)

    # 3. Tone on luminance with chroma preserved, then highlight desaturation near white.
    Y = np.maximum(rgb @ LUMA, 0.0)
    Yt = tone_curve(Y, tone)
    ratio = np.where(Y > 1e-7, Yt / np.maximum(Y, 1e-7), 0.0)
    rgb = rgb * ratio[:, None]
    w = smoothstep(tone["highlightDesaturationStart"], 1.0, Yt) * tone["highlightDesaturation"]
    rgb = rgb * (1.0 - w[:, None]) + Yt[:, None] * w[:, None]

    rgb = into_gamut(rgb, Yt)

    if "splitTone" in look:
        # Tint shadows and highlights in OKLab (perceptual), weighted by display lightness.
        st = look["splitTone"]
        lab = p3_to_oklab(rgb)
        Ld = np.clip(lab[:, 0], 0.0, 1.0)
        shadow = (1.0 - smoothstep(0.0, st.get("balance", 0.55), Ld)) * st["shadowStrength"]
        light = smoothstep(st.get("balance", 0.55), 1.0, Ld) * st["highlightStrength"]
        for weight, hue in ((shadow, st["shadowHue"]), (light, st["highlightHue"])):
            angle = math.radians(hue)
            lab[:, 1] += weight * math.cos(angle)
            lab[:, 2] += weight * math.sin(angle)
        rgb = into_gamut(oklab_to_p3(lab), np.maximum(oklab_to_p3(lab) @ LUMA, 0.0))

    if "fade" in look:
        # Lifted blacks and slightly lowered whites, like a faded print.
        fade = look["fade"]
        rgb = fade.get("black", 0.0) + (fade.get("white", 1.0) - fade.get("black", 0.0)) * rgb
    return np.clip(rgb, 0.0, 1.0)


def main() -> int:
    raw = SOURCE.read_bytes()
    look = json.loads(raw)
    digest = hashlib.sha256(raw).hexdigest()
    size = int(look["lutSize"])
    max_linear = float(look["shaper"]["maxLinear"])
    exponent = float(look["shaper"]["exponent"])

    # Node order: red fastest, then green, then blue (standard .cube order).
    s = np.linspace(0.0, 1.0, size)
    b, g, r = np.meshgrid(s, s, s, indexing="ij")
    shaped = np.stack([r.ravel(), g.ravel(), b.ravel()], axis=1)
    linear = max_linear * shaped ** exponent
    out = render(linear, look)

    cube_path = ROOT / "Resources" / "MFNaturalColour.cube"
    cube_path.parent.mkdir(parents=True, exist_ok=True)
    with cube_path.open("w") as f:
        f.write(f'TITLE "{look["name"]}"\n')
        f.write(f"# source-sha256: {digest}\n")
        f.write(f"# shaper: s = (linearP3 / {max_linear:g})^(1/{exponent:g})\n")
        f.write(f"LUT_3D_SIZE {size}\n")
        f.write("DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n")
        np.savetxt(f, out, fmt="%.5f")
    (ROOT / "Resources" / "look.json").write_bytes(raw)

    # Extra looks: base look + overrides, each in its own (smaller) cube.
    looks_dir = ROOT / "Resources" / "Looks"
    looks_dir.mkdir(parents=True, exist_ok=True)
    for stale in looks_dir.glob("*.cube"):
        stale.unlink()
    descriptors = [(look.get("id", "natural"), look["name"], "MFNaturalColour", size)]
    for extra in look.get("looks", []):
        variant = merged({k: v for k, v in look.items() if k != "looks"}, extra.get("overrides", {}))
        extra_size = int(extra.get("lutSize", 33))
        es = np.linspace(0.0, 1.0, extra_size)
        eb, eg, er = np.meshgrid(es, es, es, indexing="ij")
        e_shaped = np.stack([er.ravel(), eg.ravel(), eb.ravel()], axis=1)
        e_out = render(max_linear * e_shaped ** exponent, variant)
        resource = f"Look-{extra['id']}"
        with (looks_dir / f"{resource}.cube").open("w") as f:
            f.write(f'TITLE "{extra["name"]}"\n')
            f.write(f"# source-sha256: {digest}\n")
            f.write(f"# shaper: s = (linearP3 / {max_linear:g})^(1/{exponent:g})\n")
            f.write(f"LUT_3D_SIZE {extra_size}\n")
            f.write("DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n")
            np.savetxt(f, e_out, fmt="%.5f")
        descriptors.append((extra["id"], extra["name"], resource, extra_size))
        print(f"look {extra['id']:>10}: grey 0.18 -> {np.round(render(np.array([[0.18] * 3]), variant)[0], 3)}")

    grain = look["grain"]
    develop = look["develop"]
    weights = ", ".join(f"{w}" for w in grain["octaveWeights"])
    look_lines = "\n".join(
        f'        LookDescriptor(id: "{i}", name: "{n}", resource: "{r}", lutSize: {z}),' for i, n, r, z in descriptors
    )
    swift = f'''// Generated by tools/look/make_look.py from tools/look/look.json — do not edit by hand.
// Change look.json and re-run the script; the LUT and these constants stay in sync.

enum LookConstants {{
    static let name = "{look["name"]}"
    static let version = {int(look["version"])}
    static let sourceHash = "{digest}"
    static let lutSize = {size}
    static let shaperMaxLinear: Float = {max_linear}
    static let shaperExponent: Float = {exponent}

    // CIRAWFilter develop
    static let sharpnessAmount: Float = {develop["sharpnessAmount"]}
    static let localToneMapAmount: Float = {develop["localToneMapAmount"]}
    static let boostAmount: Float = {develop["boostAmount"]}
    static let luminanceNoiseReductionAmount: Float = {develop["luminanceNoiseReductionAmount"]}

    // Grain
    static let grainFineAmplitude: Float = {grain["fine"]["amplitude"]}
    static let grainFineSize: Float = {grain["fine"]["size"]}
    static let grainMediumAmplitude: Float = {grain["medium"]["amplitude"]}
    static let grainMediumSize: Float = {grain["medium"]["size"]}
    static let grainReferenceHeight: Float = {grain["referenceHeight"]}
    static let grainOctaveWeights: [Float] = [{weights}]
    static let grainISOBoostPerStop: Float = {grain["isoBoostPerStop"]}
    static let grainISOBoostMax: Float = {grain["isoBoostMax"]}
    static let previewGrainScale: Float = {grain["previewAmplitudeScale"]}

    // Looks (the first is the base look and the default)
    static let looks: [LookDescriptor] = [
{look_lines}
    ]
}}
'''
    swift_path = ROOT / "Sources" / "Capture" / "Edition" / "LookConstants.swift"
    swift_path.parent.mkdir(parents=True, exist_ok=True)
    swift_path.write_text(swift)

    # Report a few reference points so a look change is easy to review.
    probes = {
        "mid grey 0.18": [0.18, 0.18, 0.18],
        "white 1.0": [1.0, 1.0, 1.0],
        "highlight 4.0": [4.0, 4.0, 4.0],
        "shadow 0.01": [0.01, 0.01, 0.01],
        "skin": [0.42, 0.26, 0.19],
        "sky": [0.18, 0.30, 0.62],
        "foliage": [0.10, 0.22, 0.06],
    }
    for label, value in probes.items():
        rendered = render(np.array([value]), look)[0]
        print(f"{label:>14}: {np.round(value, 3)} -> {np.round(rendered, 3)}")
    print(f"Wrote {cube_path.relative_to(ROOT)} ({size}^3), Resources/look.json, {swift_path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
