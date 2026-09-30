"""
Proves a render's soundtrack sits exactly where the film was choreographed:
cross-correlates the render's decoded audio against the reference WAV the
composition plays (help24_audiomarketing.wav) at several points in the film.

    py audio/verify_sync.py renders/help24-film-master.mp4

A result near 0 ms at every point means every beat lands on its frame.
(Before tools/finalize.js, Remotion's renders measure +42.3 ms: AAC priming.)
"""
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
FF = HERE.parent / "remotion" / "node_modules" / "@remotion" / "compositor-win32-x64-msvc" / "ffmpeg.exe"


def load(p):
    with wave.open(str(p), "rb") as w:
        sr = w.getframerate()
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768
    return sr, x


def main(video):
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "a.wav"
        subprocess.run([str(FF), "-hide_banner", "-loglevel", "error", "-y", "-i", video,
                        "-vn", "-ac", "1", "-ar", "44100", "-c:a", "pcm_s16le", str(out)], check=True)
        sr, ref = load(HERE / "help24_audiomarketing.wav")
        sr2, got = load(out)
    assert sr == sr2
    worst = 0.0
    for t0 in (2.0, 19.0, 40.0, 55.0):
        i0, n, s = int(t0 * sr), int(4.0 * sr), int(0.2 * sr)
        r = ref[i0:i0 + n]
        seg = got[i0 - s:i0 + n + s]
        N = 1 << int(np.ceil(np.log2(len(seg) + len(r))))
        c = np.fft.irfft(np.fft.rfft(seg, N) * np.conj(np.fft.rfft(r, N)), N)[: len(seg) - len(r) + 1]
        # sub-sample peak (parabolic)
        k = int(np.argmax(c))
        if 0 < k < len(c) - 1:
            a, b, d = c[k - 1], c[k], c[k + 1]
            k = k + 0.5 * (a - d) / (a - 2 * b + d)
        ms = (k - s) / sr * 1000
        worst = max(worst, abs(ms))
        print(f"  at {t0:4.1f} s: audio offset {ms:+.2f} ms")
    print(f"{Path(video).name}: {'IN SYNC' if worst < 2 else 'OFFSET'} (worst {worst:.2f} ms)")


if __name__ == "__main__":
    main(sys.argv[1])
