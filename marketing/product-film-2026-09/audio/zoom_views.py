"""
Close-up spectrograms for listening-by-eye: vocals (gliding harmonic stacks)
vs. instruments (flat lines, hard onsets), and the shape of the ending.
Writes audio/zoom_views.png.
"""
import wave
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
with wave.open(str(HERE / "help24_audiomarketing.wav"), "rb") as w:
    sr = w.getframerate()
    x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0

N, H = 4096, 256
win = np.hanning(N)
fr_all = np.lib.stride_tricks.sliding_window_view(x, N)[::H]
S = 20 * np.log10(np.abs(np.fft.rfft(fr_all * win, axis=1)).T + 1e-7)
f = np.fft.rfftfreq(N, 1 / sr)
t = np.arange(S.shape[1]) * H / sr + N / 2 / sr

views = [(0.0, 7.2), (14.3, 21.5), (26.3, 33.5), (40.7, 47.9), (52.7, 60.5)]
fig, ax = plt.subplots(len(views) + 1, 1, figsize=(26, 5 * (len(views) + 1)))
fm = f <= 3500
for a, (t0, t1) in zip(ax, views):
    m = (t >= t0) & (t <= t1)
    sub = S[fm][:, m]
    a.imshow(sub, origin="lower", aspect="auto", extent=[t0, t1, 0, 3500], cmap="magma",
             vmin=np.percentile(sub, 55), vmax=np.percentile(sub, 99.7))
    for k in range(0, 101):
        bt = 0.5 + 0.6 * k
        if t0 <= bt <= t1:
            a.axvline(bt, color="w" if k % 4 == 3 else "#E8A33D", lw=1.4 if k % 4 == 3 else 0.5, alpha=0.8)
    a.set_title(f"{t0:.1f}-{t1:.1f}s  (white = bar downbeat, amber = beat)")
    a.set_ylabel("Hz")
# ending: raw waveform, last 4 s
m = (np.arange(len(x)) / sr) >= 56.5
ax[-1].plot(np.arange(len(x))[m] / sr, x[m], lw=0.4, color="#333")
for k in range(93, 101):
    bt = 0.5 + 0.6 * k
    ax[-1].axvline(bt, color="#c0392b" if k % 4 == 3 else "#E8A33D", lw=1.2)
ax[-1].set_title("ending waveform 56.5s-end (red = downbeat)")
ax[-1].set_xticks(np.arange(56.5, 60.6, 0.1), minor=True)
ax[-1].grid(which="both", axis="x", alpha=0.3)
plt.tight_layout()
plt.savefig(HERE / "zoom_views.png", dpi=55)
print("ok")
