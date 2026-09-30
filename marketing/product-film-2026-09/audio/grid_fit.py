"""
Second pass: fit a strict beat grid and draw a bar-by-bar drum map.

The DP beat tracker in analyze_audio.py drifts through the drop-outs, so this
fits period + phase directly against low-band (kick) and high-band (hat/snare)
onsets, then renders each 4-beat bar as one row so accents and any phase shift
are visible at a glance.  Writes audio/grid.json and audio/drum_map.png.
"""
import json
import wave
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
with wave.open(str(HERE / "help24_audiomarketing.wav"), "rb") as w:
    sr = w.getframerate()
    x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
dur = len(x) / sr

N_FFT, HOP = 1024, 128                       # finer hop: ~2.9 ms
win = np.hanning(N_FFT)
n_frames = 1 + (len(x) - N_FFT) // HOP
frames = np.lib.stride_tricks.sliding_window_view(x, N_FFT)[::HOP][:n_frames]
S = np.abs(np.fft.rfft(frames * win, axis=1)).T
f = np.fft.rfftfreq(N_FFT, 1 / sr)
fr = sr / HOP
t = np.arange(S.shape[1]) / fr + N_FFT / 2 / sr
L = np.log(S + 1e-6)


def band_flux(lo, hi):
    m = (f >= lo) & (f < hi)
    d = np.maximum(0, np.diff(L[m], axis=1)).mean(0)
    d = np.concatenate([[0], d])
    d -= np.median(d)
    return np.maximum(0, d) / (np.percentile(d, 99.5) + 1e-9)


kick = band_flux(30, 150)
snare = band_flux(150, 2500)
hat = band_flux(6000, 16000)
allb = band_flux(30, 16000)


def comb_score(o, period, phase, t0=0.0, t1=None):
    t1 = dur if t1 is None else t1
    ks = np.arange(np.ceil((t0 - phase) / period), np.floor((t1 - phase) / period) + 1)
    pos = phase + ks * period
    idx = np.clip(np.round((pos - t[0]) * fr).astype(int), 0, len(o) - 1)
    # take max within +/- 15 ms to tolerate tiny drift
    r = int(0.015 * fr)
    return np.mean([o[max(0, i - r):i + r + 1].max() for i in idx])


# global period search on the full-band flux
best = None
for period in np.arange(0.590, 0.6105, 0.0005):
    for phase in np.arange(0, period, 0.005):
        s = comb_score(allb, period, phase)
        if best is None or s > best[0]:
            best = (s, period, phase)
_, P, PH = best
print(f"global grid: period={P:.4f}s ({60 / P:.2f} BPM) phase={PH:.3f}s score={best[0]:.3f}")

# per-section local phase, to catch a half-beat shift after a break
sections = [(0.0, 16.6), (16.6, 19.2), (19.2, 37.8), (37.8, 40.7), (40.7, 53.0), (53.0, 55.0), (55.0, 59.4)]
local = []
for a, b in sections:
    sc = []
    for phase in np.arange(0, P, 0.005):
        sc.append((comb_score(kick, P, phase, a, b) + comb_score(allb, P, phase, a, b), phase))
    s, ph = max(sc)
    # express as offset from the global grid, wrapped to (-P/2, P/2]
    off = ((ph - PH + P / 2) % P) - P / 2
    local.append({"from": a, "to": b, "phase": round(ph, 3), "offset_from_global": round(off, 3), "score": round(s, 3)})
    print(f"  {a:5.1f}-{b:5.1f}s  best phase {ph:.3f}  offset {off:+.3f}s  score {s:.3f}")

# kick vs snare placement per beat position within a bar, on the global grid
beats = PH + np.arange(0, int((dur - PH) / P) + 1) * P


def at(o, tt):
    i = int(round((tt - t[0]) * fr))
    r = int(0.02 * fr)
    return float(o[max(0, i - r):i + r + 1].max()) if 0 <= i < len(o) else 0.0


rows = []
for i, b in enumerate(beats):
    rows.append({"i": i, "t": round(float(b), 3), "kick": round(at(kick, b), 2), "snare": round(at(snare, b), 2),
                 "hat": round(at(hat, b), 2), "off_kick": round(at(kick, b + P / 2), 2),
                 "off_hat": round(at(hat, b + P / 2), 2)})

# figure out which of the 4 positions carries the strongest kick -> bar phase
pos_k = [np.mean([r["kick"] for r in rows[p::4]]) for p in range(4)]
pos_s = [np.mean([r["snare"] for r in rows[p::4]]) for p in range(4)]
print("kick by position", np.round(pos_k, 3), " snare by position", np.round(pos_s, 3))

json.dump({"period_s": round(P, 4), "bpm": round(60 / P, 2), "phase_s": round(PH, 3), "local": local,
           "beats": rows, "kick_by_pos": [round(v, 3) for v in pos_k], "snare_by_pos": [round(v, 3) for v in pos_s]},
          open(HERE / "grid.json", "w"), indent=1)

# ---------------- drum map: one row per bar (4 beats), columns = time within bar
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BAR = 4 * P
n_bars = int(np.ceil((dur - PH) / BAR))
res = 240
maps = {}
for name, o in [("kick 30-150Hz", kick), ("snare/mid 150-2.5k", snare), ("hat 6-16k", hat)]:
    img = np.zeros((n_bars, res))
    for bi in range(n_bars):
        tt = PH + bi * BAR + np.arange(res) / res * BAR
        idx = np.clip(np.round((tt - t[0]) * fr).astype(int), 0, len(o) - 1)
        img[bi] = o[idx]
    maps[name] = img

fig, ax = plt.subplots(1, 3, figsize=(24, 12))
for a, (name, img) in zip(ax, maps.items()):
    a.imshow(np.clip(img, 0, 1), aspect="auto", cmap="gray_r", interpolation="nearest",
             extent=[0, 4, n_bars, 0])
    a.set_title(name)
    a.set_xticks([0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4])
    a.set_xlabel("beat within bar")
    a.set_yticks(np.arange(n_bars) + 0.5)
    a.set_yticklabels([f"bar {b:2d}  {PH + b * BAR:5.2f}s" for b in range(n_bars)], fontsize=8)
    for xv in range(5):
        a.axvline(xv, color="#E8A33D", lw=0.8)
plt.suptitle(f"drum map — grid period {P:.4f}s ({60 / P:.2f} BPM), phase {PH:.3f}s; each row = one 4-beat bar")
plt.tight_layout()
plt.savefig(HERE / "drum_map.png", dpi=60)
