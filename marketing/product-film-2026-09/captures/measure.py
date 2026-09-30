"""
Measuring helpers used while building the film (not needed at render time).

  py captures/measure.py rows <name> [x0 x1] [y0 y1]   content runs down the screen
  py captures/measure.py cols <name> y0 y1             content runs across a band
  py captures/measure.py offset <a> <b> y0 y1          vertical scroll delta a -> b
  py captures/measure.py dark <name> x0 y0 x1 y1       bbox of ink-coloured pixels
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent


def load(name):
    p = HERE / "processed" / f"{name}.png"
    if not p.exists():
        p = Path(name)
    return np.asarray(Image.open(p).convert("RGB")).astype(np.int32)


def runs(mask, min_len=1):
    out, start = [], None
    for i, v in enumerate(mask):
        if v and start is None:
            start = i
        elif not v and start is not None:
            if i - start >= min_len:
                out.append((start, i - 1))
            start = None
    if start is not None:
        out.append((start, len(mask) - 1))
    return out


def rows(name, x0=0, x1=1080, y0=0, y1=2400, bg=None, thr=18):
    a = load(name)[y0:y1, x0:x1]
    bg = np.array(bg if bg else a[:, :].reshape(-1, 3)[np.argmax(np.bincount(
        (a.reshape(-1, 3) @ np.array([65536, 256, 1])).astype(np.int64)))] if False else [250, 249, 247])
    d = np.abs(a - bg).sum(axis=2) > thr
    frac = d.mean(axis=1)
    for s, e in runs(frac > 0.004):
        print(f"  rows {s + y0:5d}-{e + y0:5d}  h={e - s + 1:4d}  peak={frac[s:e + 1].max():.2f}")


def cols(name, y0, y1, thr=18):
    a = load(name)[y0:y1]
    bg = np.array([250, 249, 247])
    d = (np.abs(a - bg).sum(axis=2) > thr).mean(axis=0)
    for s, e in runs(d > 0.01):
        print(f"  cols {s:5d}-{e:5d}  w={e - s + 1:4d}")


def offset(a_name, b_name, y0, y1, x0=40, x1=700, search=(0, 1600)):
    A, B = load(a_name), load(b_name)
    ref = A[y0:y1, x0:x1]
    best = None
    for d in range(search[0], search[1]):
        if y0 - d < 0 or y1 - d > B.shape[0]:
            continue
        sad = np.abs(B[y0 - d:y1 - d, x0:x1] - ref).mean()
        if best is None or sad < best[0]:
            best = (sad, d)
    print(f"  content moved up by {best[1]} px (mean abs diff {best[0]:.2f})")
    return best[1]


def dark(name, x0, y0, x1, y1, thr=90):
    a = load(name)[y0:y1, x0:x1]
    m = a.sum(axis=2) < thr * 3
    ys, xs = np.where(m)
    print(f"  dark bbox x {xs.min() + x0}-{xs.max() + x0}  y {ys.min() + y0}-{ys.max() + y0}")


if __name__ == "__main__":
    cmd, *args = sys.argv[1:]
    if cmd == "rows":
        n = args[0]
        nums = list(map(int, args[1:]))
        x0, x1 = (nums[0], nums[1]) if len(nums) >= 2 else (0, 1080)
        y0, y1 = (nums[2], nums[3]) if len(nums) >= 4 else (0, 2400)
        rows(n, x0, x1, y0, y1)
    elif cmd == "cols":
        cols(args[0], int(args[1]), int(args[2]))
    elif cmd == "offset":
        offset(args[0], args[1], int(args[2]), int(args[3]))
    elif cmd == "dark":
        dark(args[0], *map(int, args[1:5]))
