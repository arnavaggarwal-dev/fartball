# Lists the separate farts inside sfx/source/gastricdistress_bylfa_0.wav (CC0, LFA, OpenGameArt).
import sys, wave
import numpy as np

def load(path):
    w = wave.open(path)
    x = np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768
    return x, w.getframerate()

def slices(x, sr, thresh_db=-38, min_gap=0.12, min_len=0.08):
    hop = int(sr * 0.01)
    rms = np.sqrt(np.convolve(x * x, np.ones(hop) / hop, "same"))[::hop]
    on = 20 * np.log10(rms + 1e-9) > thresh_db
    segs, start, quiet = [], None, 0
    for i, v in enumerate(on):
        if v:
            start = i if start is None else start
            quiet = 0
        elif start is not None:
            quiet += 1
            if quiet * 0.01 >= min_gap:
                end = i - quiet + 1
                if (end - start) * 0.01 >= min_len:
                    segs.append((start * hop, end * hop))
                start, quiet = None, 0
    if start is not None:
        segs.append((start * hop, len(x)))
    return segs

if __name__ == "__main__":
    x, sr = load(sys.argv[1])
    for k, (a, b) in enumerate(slices(x, sr)):
        s = x[a:b]
        spec = np.abs(np.fft.rfft(s * np.hanning(len(s))))
        f = np.fft.rfftfreq(len(s), 1 / sr)
        cen = (spec * f).sum() / spec.sum()
        print(f"{k:2d} t={a/sr:6.2f}s dur={(b-a)/sr:5.2f}s peak={np.abs(s).max():.2f} rms={np.sqrt((s*s).mean()):.3f} centroid={cen:5.0f}Hz")
