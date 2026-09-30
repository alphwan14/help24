"""
Help24 product film - audio analysis.

Reads audio/help24_audiomarketing.wav and writes:
  audio/analysis.json   tempo, beats, bar phase, onsets, sections, energy curve
  audio/analysis.png    waveform/RMS, spectrogram, onset strength + beats, novelty

Everything here is plain numpy (scipy's compiled modules are blocked by the
Application Control policy on the machine this was built on), so it can be
re-run anywhere when the track is swapped:
    py audio/analyze_audio.py [path/to/track.wav]
"""
import json
import sys
import wave
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
WAV = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "help24_audiomarketing.wav"


def read_wav(p):
    with wave.open(str(p), "rb") as w:
        sr_, ch, sw = w.getframerate(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(w.getnframes())
    assert sw == 2, "expects 16-bit PCM (decode with ffmpeg -c:a pcm_s16le)"
    a = np.frombuffer(raw, dtype="<i2").astype(np.float64).reshape(-1, ch).mean(axis=1)
    return sr_, a / 32768.0


def uniform_filter1d(v, size):
    k = np.ones(int(size)) / int(size)
    return np.convolve(v, k, mode="same")


def dct(m, n):
    """Orthonormal DCT-II along axis 0, first n coefficients."""
    N = m.shape[0]
    k = np.arange(n)[:, None]
    i = np.arange(N)[None, :]
    basis = np.cos(np.pi / N * (i + 0.5) * k) * np.sqrt(2 / N)
    basis[0] /= np.sqrt(2)
    return basis @ m


def find_peaks(v, height=0.0, distance=1):
    """Local maxima above height, greedily keeping the tallest within distance."""
    cand = np.where((v[1:-1] > v[:-2]) & (v[1:-1] >= v[2:]) & (v[1:-1] >= height))[0] + 1
    order = cand[np.argsort(-v[cand])]
    taken = np.zeros(len(v), dtype=bool)
    keep = []
    for p in order:
        if not taken[max(0, p - distance + 1):p + distance].any():
            keep.append(p)
            taken[p] = True
    return np.array(sorted(keep), dtype=int), {}


sr, x = read_wav(WAV)
dur = len(x) / sr

# ---------------------------------------------------------------- STFT
N_FFT, HOP = 2048, 512
win = np.hanning(N_FFT)
n_frames = 1 + (len(x) - N_FFT) // HOP
frames = np.lib.stride_tricks.sliding_window_view(x, N_FFT)[::HOP][:n_frames]
S = np.abs(np.fft.rfft(frames * win, axis=1)).T   # magnitude, (freq, frames)
f = np.fft.rfftfreq(N_FFT, 1 / sr)
fr = sr / HOP                        # frames per second (~86.13)
times = np.arange(S.shape[1]) * HOP / sr + N_FFT / 2 / sr


def mel_fb(n_mels=64, fmin=30, fmax=16000):
    def hz2mel(h): return 2595 * np.log10(1 + h / 700)
    def mel2hz(m): return 700 * (10 ** (m / 2595) - 1)
    mpts = np.linspace(hz2mel(fmin), hz2mel(fmax), n_mels + 2)
    hz = mel2hz(mpts)
    fb = np.zeros((n_mels, len(f)))
    for i in range(n_mels):
        lo, c, hi = hz[i], hz[i + 1], hz[i + 2]
        up = (f - lo) / (c - lo)
        dn = (hi - f) / (hi - c)
        fb[i] = np.maximum(0, np.minimum(up, dn))
    return fb, hz[1:-1]


FB, mel_centers = mel_fb()
M = FB @ (S ** 2)
logM = 10 * np.log10(M + 1e-10)

# ---------------------------------------------------------------- loudness
rms = np.sqrt(uniform_filter1d(x ** 2, size=int(0.05 * sr)))
rms_t = np.arange(len(rms)) / sr
rms_db = 20 * np.log10(rms + 1e-9)
# per-frame (30 fps) loudness for the video timeline
FPS = 30
n_vid = int(np.ceil(dur * FPS))
energy_30 = []
for i in range(n_vid):
    a, b = int(i / FPS * sr), int((i + 1) / FPS * sr)
    seg = x[a:b]
    energy_30.append(float(np.sqrt(np.mean(seg ** 2))) if len(seg) else 0.0)
energy_30 = np.array(energy_30)
energy_30_db = 20 * np.log10(energy_30 + 1e-9)


# ---------------------------------------------------------------- onset strength
def flux(logspec):
    d = np.diff(logspec, axis=1)
    d = np.maximum(0, d)
    o = d.mean(axis=0)
    o = np.concatenate([[0], o])
    return o


onset = flux(logM)
low_idx = mel_centers < 180
mid_idx = (mel_centers >= 180) & (mel_centers < 2500)
high_idx = mel_centers >= 2500
onset_low = flux(logM[low_idx])
onset_mid = flux(logM[mid_idx])
onset_high = flux(logM[high_idx])


def norm(v):
    v = v - np.median(v)
    return v / (np.percentile(np.abs(v), 99) + 1e-9)


onset_n = norm(onset)

# ---------------------------------------------------------------- tempo
def tempo_from(o, lo_bpm=60, hi_bpm=180, prior=110):
    o = o - o.mean()
    ac = np.correlate(o, o, mode="full")[len(o) - 1:]
    ac /= ac[0] + 1e-9
    lags = np.arange(len(ac))
    bpm = 60 * fr / np.maximum(lags, 1)
    valid = (bpm >= lo_bpm) & (bpm <= hi_bpm)
    w = np.exp(-0.5 * (np.log2(bpm / prior) / 1.0) ** 2)
    score = np.where(valid, ac * w, -np.inf)
    lag = int(np.argmax(score))
    # parabolic refinement
    if 1 <= lag < len(ac) - 1:
        a, b, c = ac[lag - 1], ac[lag], ac[lag + 1]
        p = 0.5 * (a - c) / (a - 2 * b + c + 1e-12)
    else:
        p = 0
    lagf = lag + p
    cands = sorted([(float(60 * fr / l), float(ac[l])) for l in range(1, len(ac))
                    if valid[l] and ac[l] > 0 and ac[l] == ac[max(0, l - 3):l + 4].max()],
                   key=lambda z: -z[1])[:8]
    return 60 * fr / lagf, cands


bpm, bpm_cands = tempo_from(onset_n)


# ---------------------------------------------------------------- beat tracking (Ellis 2007 DP)
def track_beats(o, bpm, tightness=120):
    period = 60 * fr / bpm
    o = o / (o.std() + 1e-9)
    # local score: onset smoothed by a gaussian of width period/32
    win = np.exp(-0.5 * (np.arange(-period, period + 1) * 32 / period) ** 2)
    local = np.convolve(o, win, "same")
    n = len(local)
    backlink = -np.ones(n, dtype=int)
    cum = local.copy()
    lo, hi = int(round(-2 * period)), int(round(-period / 2))
    window = np.arange(lo, hi + 1)
    txcost = -tightness * (np.log(-window / period) ** 2)
    for i in range(n):
        z = i + window
        valid = z >= 0
        if not valid.any():
            continue
        cand = txcost[valid] + cum[z[valid]]
        j = int(np.argmax(cand))
        cum[i] = local[i] + cand[j]
        backlink[i] = z[valid][j]
    # start from the best score in the last period
    tail = np.arange(max(0, n - int(period)), n)
    b = int(tail[np.argmax(cum[tail])])
    beats = [b]
    while backlink[b] >= 0:
        b = backlink[b]
        beats.append(b)
    beats = np.array(beats[::-1])
    # trim weak leading/trailing beats
    th = 0.5 * np.median(local[beats])
    keep = np.where(local[beats] > th)[0]
    if len(keep):
        beats = beats[keep[0]:keep[-1] + 1]
    return beats, local


beat_frames, local = track_beats(onset_n, bpm)
beat_times = times[beat_frames]


# refine each beat to the nearest onset peak within +/- 40ms
def refine(frames, o, radius_s=0.04):
    r = int(radius_s * fr)
    out = []
    for b in frames:
        a, c = max(0, b - r), min(len(o), b + r + 1)
        out.append(a + int(np.argmax(o[a:c])))
    return np.array(out)


beat_frames_ref = refine(beat_frames, onset_n)
beat_times_ref = times[beat_frames_ref]

# ---------------------------------------------------------------- bar phase (4/4 assumed)
low_n = norm(onset_low)
accent = []
for k in range(4):
    idx = beat_frames_ref[k::4]
    accent.append(float(np.mean(low_n[idx]) + 0.5 * np.mean(onset_n[idx])))
phase = int(np.argmax(accent))
downbeats = beat_times_ref[phase::4]

# ---------------------------------------------------------------- MFCC + chroma per beat -> novelty
def mfcc(logm, n=20):
    return dct(logm, n)


MF = mfcc(logM)

# chroma
pitch_hz = 440 * 2 ** ((np.arange(128) - 69) / 12)
chroma_fb = np.zeros((12, len(f)))
for fi, fq in enumerate(f):
    if 55 <= fq <= 5000:
        midi = 69 + 12 * np.log2(fq / 440)
        pc = int(np.round(midi)) % 12
        wgt = np.exp(-0.5 * ((midi - np.round(midi)) / 0.25) ** 2)
        chroma_fb[pc, fi] += wgt
C = chroma_fb @ S
C = C / (C.sum(axis=0, keepdims=True) + 1e-9)

bounds = np.concatenate([[0], beat_frames_ref, [S.shape[1]]])


def sync(F):
    out = []
    for a, b in zip(bounds[:-1], bounds[1:]):
        b = max(b, a + 1)
        out.append(F[:, a:b].mean(axis=1))
    return np.array(out).T


MFb = sync(MF)
Cb = sync(C)
Eb = sync(logM.mean(axis=0, keepdims=True))[0]
feat = np.vstack([
    (MFb - MFb.mean(1, keepdims=True)) / (MFb.std(1, keepdims=True) + 1e-9),
    (Cb - Cb.mean(1, keepdims=True)) / (Cb.std(1, keepdims=True) + 1e-9),
])
fn = feat / (np.linalg.norm(feat, axis=0, keepdims=True) + 1e-9)
SSM = fn.T @ fn


def checker_novelty(ssm, L=8):
    g = np.exp(-0.5 * (np.linspace(-1, 1, 2 * L) / 0.5) ** 2)
    k = np.outer(g, g) * np.outer(np.r_[-np.ones(L), np.ones(L)], np.r_[-np.ones(L), np.ones(L)])
    n = ssm.shape[0]
    pad = np.pad(ssm, L, mode="edge")
    nov = np.array([np.sum(pad[i:i + 2 * L, i:i + 2 * L] * k) for i in range(n)])
    nov = np.maximum(0, nov)
    return nov / (nov.max() + 1e-9)


nov8 = checker_novelty(SSM, 8)
nov4 = checker_novelty(SSM, 4)
seg_times = np.concatenate([[0], beat_times_ref])  # time at start of each beat segment
pk, _ = find_peaks(nov8, height=0.25, distance=6)
sections = [float(seg_times[p]) for p in pk]

# ---------------------------------------------------------------- strong onsets (accents / hits)
peaks, props = find_peaks(onset_n, height=0.35, distance=int(0.12 * fr))
strong = sorted([(float(times[p]), float(onset_n[p]), float(norm(onset_low)[p]), float(norm(onset_high)[p]))
                 for p in peaks], key=lambda z: z[0])

# ---------------------------------------------------------------- speech-vs-music heuristics
# (1) beat regularity: std of inter-beat intervals
ibi = np.diff(beat_times_ref)
# (2) modulation spectrum of the 300-3000 Hz envelope: speech peaks ~3-6 Hz
band = (f > 300) & (f < 3000)
env = S[band].sum(axis=0)
env = (env - env.mean()) / (env.std() + 1e-9)
spec = np.abs(np.fft.rfft(env * np.hanning(len(env))))
mfreq = np.fft.rfftfreq(len(env), 1 / fr)
def band_power(lo, hi): return float(spec[(mfreq >= lo) & (mfreq < hi)].sum())
mod_ratio = band_power(3, 7) / (band_power(0.5, 3) + band_power(7, 15) + 1e-9)
# (3) spectral centroid + flatness
cent = (f[:, None] * S).sum(0) / (S.sum(0) + 1e-9)
flat = np.exp(np.mean(np.log(S + 1e-9), axis=0)) / (S.mean(0) + 1e-9)

# ---------------------------------------------------------------- per-second summary
per_sec = []
for s in range(int(np.ceil(dur))):
    m = (times >= s) & (times < s + 1)
    mr = (rms_t >= s) & (rms_t < s + 1)
    per_sec.append({
        "t": s,
        "rms_db": round(float(np.mean(rms_db[mr])), 1),
        "low": round(float(np.mean(logM[low_idx][:, m])), 1),
        "mid": round(float(np.mean(logM[mid_idx][:, m])), 1),
        "high": round(float(np.mean(logM[high_idx][:, m])), 1),
        "centroid": int(np.mean(cent[m])),
        "onset": round(float(np.mean(onset_n[m])), 3),
    })

out = {
    "file": WAV.name,
    "sample_rate": int(sr),
    "duration_s": round(dur, 3),
    "tempo_bpm": round(float(bpm), 2),
    "tempo_candidates": [(round(b, 2), round(s, 3)) for b, s in bpm_cands],
    "beat_period_s": round(60 / float(bpm), 4),
    "beats_s": [round(float(b), 3) for b in beat_times_ref],
    "ibi_mean_s": round(float(ibi.mean()), 4) if len(ibi) else None,
    "ibi_std_s": round(float(ibi.std()), 4) if len(ibi) else None,
    "bar_phase_index": phase,
    "bar_phase_accent": [round(a, 3) for a in accent],
    "downbeats_s": [round(float(d), 3) for d in downbeats],
    "section_boundaries_s": [round(s, 3) for s in sections],
    "novelty_per_beat": [round(float(v), 3) for v in nov8],
    "strong_onsets": [{"t": round(a, 3), "all": round(b, 2), "low": round(c, 2), "high": round(d, 2)} for a, b, c, d in strong],
    "speech_modulation_ratio": round(mod_ratio, 3),
    "per_second": per_sec,
    "energy_30fps_db": [round(float(v), 1) for v in energy_30_db],
}
(HERE / "analysis.json").write_text(json.dumps(out, indent=1))

# ---------------------------------------------------------------- plot
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

fig, ax = plt.subplots(5, 1, figsize=(26, 17), sharex=True,
                       gridspec_kw={"height_ratios": [1.2, 2.2, 1.2, 1.0, 1.0]})
ax[0].plot(np.arange(len(x)) / sr, x, lw=0.3, color="#888")
ax[0].plot(rms_t, rms * 3, color="#E8A33D", lw=1.2)
ax[0].set_ylabel("wave / rms")
ax[1].imshow(logM, origin="lower", aspect="auto", extent=[times[0], times[-1], 0, logM.shape[0]],
             cmap="magma", vmin=np.percentile(logM, 30), vmax=np.percentile(logM, 99.5))
yt = [0, 10, 20, 30, 40, 50, 63]
ax[1].set_yticks(yt)
ax[1].set_yticklabels([f"{int(mel_centers[min(i, len(mel_centers) - 1)])}" for i in yt])
ax[1].set_ylabel("mel (Hz)")
ax[2].plot(times, onset_n, lw=0.7, color="#333", label="onset")
ax[2].plot(times, norm(onset_low) * 0.8 - 1.2, lw=0.7, color="#c0392b", label="low (kick)")
ax[2].plot(times, norm(onset_high) * 0.8 - 2.4, lw=0.7, color="#2980b9", label="high (hats)")
for b in beat_times_ref:
    ax[2].axvline(b, color="#E8A33D", lw=0.6, alpha=0.6)
for d in downbeats:
    ax[2].axvline(d, color="#12161A", lw=1.2, alpha=0.8)
ax[2].legend(loc="upper right")
ax[2].set_ylabel("onsets")
ax[3].plot(seg_times, nov8, color="#12161A", label="novelty L=8")
ax[3].plot(seg_times, nov4, color="#999", lw=0.8, label="novelty L=4")
for s in sections:
    ax[3].axvline(s, color="#c0392b", lw=1.5)
ax[3].legend(loc="upper right")
ax[4].plot(times, cent, lw=0.5, color="#2980b9")
ax[4].set_ylabel("centroid Hz")
ax[4].set_xlabel("seconds")
for a in ax:
    a.set_xticks(np.arange(0, dur + 1, 1))
    a.grid(axis="x", alpha=0.25)
ax[0].set_title(f"{WAV.name}  dur={dur:.2f}s  tempo={bpm:.1f} BPM  phase={phase}  sections={['%.2f' % s for s in sections]}")
plt.tight_layout()
plt.savefig(HERE / "analysis.png", dpi=62)
print(json.dumps({k: out[k] for k in ["duration_s", "tempo_bpm", "tempo_candidates", "beat_period_s",
                                       "ibi_mean_s", "ibi_std_s", "bar_phase_index", "bar_phase_accent",
                                       "section_boundaries_s", "speech_modulation_ratio"]}, indent=1))
print("beats:", out["beats_s"])
print("downbeats:", out["downbeats_s"])
for p in per_sec:
    print(p)
