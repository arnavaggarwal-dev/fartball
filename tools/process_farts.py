# Turns the CC0 "Gastric Distress" recording (LFA, opengameart.org/content/gastric-distress)
# into the game's fart variants: sfx/fart_<class>_<n>.wav.
# Run: python -P tools/process_farts.py
import os, sys, wave
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fart_slices import load, slices


def biquad(x, kind, f, q, sr=44100):
    """RBJ low-pass ("lp") or band-pass ("bp") filter."""
    w0 = 2 * np.pi * f / sr
    al, c = np.sin(w0) / (2 * q), np.cos(w0)
    b0, b1, b2 = ((1 - c) / 2, 1 - c, (1 - c) / 2) if kind == "lp" else (al, 0.0, -al)
    a0, a1, a2 = 1 + al, -2 * c, 1 - al
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        v = (b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2, x1, y2, y1 = x1, x[i], y1, v
        y[i] = v
    return y

ROOT = os.path.join(os.path.dirname(__file__), "..")
SRC = os.path.join(ROOT, "sfx", "source", "gastricdistress_bylfa_0.wav")

# class: (slice indices from fart_slices.py, max seconds, pitch factor, target RMS dBFS)
# Durations track the thrust burns; bigger farts are deeper and louder.
CLASSES = {
    "burst": ([5, 9, 12], 0.3, 1.15, -15),
    "small": ([4, 12, 13], 0.5, 1.05, -14),
    "mid": ([6, 8, 10, 2], 0.8, 0.95, -13),
    "big": ([0, 1, 11], 1.3, 0.8, -12),
}


def process(seg, sr, max_len, pitch, target_db):
    # pitch shift by resampling (also stretches length, like a slower, bigger fart)
    n = int(len(seg) / pitch)
    seg = np.interp(np.arange(n) * pitch, np.arange(len(seg)), seg)
    seg = seg[: int(max_len * sr)]
    # tame the mouth-recording hiss, then layer extra bottom end
    body = biquad(seg, "lp", 2600, 0.7)
    bass = biquad(seg, "lp", 380, 0.9)
    out = body + 0.9 * bass
    # 5 ms fade in, fade the last 35% out to follow the decaying thrust
    t = np.arange(len(out))
    fade_in = np.clip(t / (0.005 * sr), 0, 1)
    k = int(len(out) * 0.35)
    fade_out = np.ones(len(out))
    fade_out[-k:] = np.cos(np.linspace(0, np.pi / 2, k)) ** 2
    out *= fade_in * fade_out
    out *= 10 ** (target_db / 20) / (np.sqrt((out * out).mean()) + 1e-9)
    return 0.95 * np.tanh(out / 0.95)  # soft clip, ceiling 0.95


def save(path, x, sr):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())


if __name__ == "__main__":
    x, sr = load(SRC)
    segs = slices(x, sr)
    pre = int(0.02 * sr)
    for name, (picks, max_len, pitch, db) in CLASSES.items():
        for n, i in enumerate(picks, 1):
            a, b = segs[i]
            out = process(x[max(0, a - pre):b], sr, max_len, pitch, db)
            path = os.path.join(ROOT, "sfx", f"fart_{name}_{n}.wav")
            save(path, out, sr)
            spec = np.abs(np.fft.rfft(out))
            cen = (spec * np.fft.rfftfreq(len(out), 1 / sr)).sum() / spec.sum()
            print(f"{os.path.basename(path)}  {len(out) / sr:.2f}s  peak={np.abs(out).max():.2f}  centroid={cen:.0f}Hz")
