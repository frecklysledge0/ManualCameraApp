#!/usr/bin/env python3
"""Generates the Edition's bundled assets (Slice 3):

  Resources/BlueNoise64.png   64×64 blue-noise texture for film grain (void-and-cluster)
  Resources/LeafShutter.caf   original synthesised leaf-shutter sound, 48 kHz mono, ~75 ms

    python3 tools/look/make_assets.py      (needs numpy, Pillow and ffmpeg)

Both assets are original works generated here; replace LeafShutter.caf with your own recording
(48 kHz CAF, short and soft) if you prefer.
"""
import subprocess, sys, tempfile, wave
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "Resources"


def blue_noise(size=64, sigma=1.9, seed=7):
    """Ulichney's void-and-cluster on a torus."""
    rng = np.random.default_rng(seed)
    n = size * size
    f = np.fft.fftfreq(size)
    gauss = np.exp(-2 * (np.pi * sigma) ** 2 * (f[:, None] ** 2 + f[None, :] ** 2))
    def energy(m): return np.real(np.fft.ifft2(np.fft.fft2(m) * gauss))
    pattern = rng.random((size, size)) < 0.1
    # Relax the initial pattern: move the tightest cluster to the largest void until stable.
    for _ in range(4 * n):
        e = energy(pattern.astype(float))
        cluster = np.unravel_index(np.argmax(np.where(pattern, e, -np.inf)), pattern.shape)
        pattern[cluster] = False
        e = energy(pattern.astype(float))
        void = np.unravel_index(np.argmin(np.where(pattern, np.inf, e)), pattern.shape)
        pattern[void] = True
        if void == cluster:
            break
    ranks = np.zeros((size, size), dtype=np.int64)
    ones = int(pattern.sum())
    proto = pattern.copy()
    for rank in range(ones - 1, -1, -1):
        e = energy(proto.astype(float))
        cluster = np.unravel_index(np.argmax(np.where(proto, e, -np.inf)), proto.shape)
        proto[cluster] = False
        ranks[cluster] = rank
    proto = pattern.copy()
    for rank in range(ones, n):
        e = energy(proto.astype(float))
        void = np.unravel_index(np.argmin(np.where(proto, np.inf, e)), proto.shape)
        proto[void] = True
        ranks[void] = rank
    return ((ranks + 0.5) / n * 255).astype(np.uint8)


def leaf_shutter(rate=48000):
    """Two soft clicks ("tk-tk") 28 ms apart: damped resonances plus a tiny noise transient."""
    t = np.arange(int(rate * 0.078)) / rate
    out = np.zeros_like(t)
    rng = np.random.default_rng(3)
    for start, gain, freq in ((0.0, 1.0, 2350.0), (0.028, 0.72, 1900.0)):
        local = t - start
        mask = local >= 0
        lt = local[mask]
        body = np.sin(2 * np.pi * freq * lt) * np.exp(-lt / 0.0045)
        thump = np.sin(2 * np.pi * 420.0 * lt) * np.exp(-lt / 0.009) * 0.45
        tick = rng.normal(0, 1, lt.size) * np.exp(-lt / 0.0012) * 0.5
        out[mask] += gain * (body + thump + tick)
    fade = np.minimum(1, (len(t) - np.arange(len(t))) / (rate * 0.008))
    out *= fade
    out = out / np.max(np.abs(out)) * 10 ** (-6 / 20)
    return (out * 32767).astype(np.int16), rate


def main():
    RES.mkdir(exist_ok=True)
    noise = blue_noise()
    Image.fromarray(noise, mode="L").save(RES / "BlueNoise64.png")
    samples, rate = leaf_shutter()
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / "shutter.wav"
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
            w.writeframes(samples.tobytes())
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-c:a", "pcm_s16le", str(RES / "LeafShutter.caf")], check=True)
    print("Wrote Resources/BlueNoise64.png and Resources/LeafShutter.caf")


if __name__ == "__main__":
    sys.exit(main())
