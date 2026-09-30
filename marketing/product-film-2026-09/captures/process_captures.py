"""
Help24 product film - capture processing.

Copies the real ADB captures used by the film into captures/raw/ (untouched),
then writes captures/processed/ + remotion/public/screens/ with OS CHROME ONLY
cleaned. No Help24 pixel is changed:

  1. Android status bar (rows 0-83) -> filled with the screen's own background,
     sampled column-by-column from row 80 of the same capture. The film draws one
     consistent status bar (10:30, wifi, signal, battery) on top, as the Play
     Store set did, so six different clock times and battery levels don't flicker
     between scenes.
  2. Samsung Edge Panel handle (a grey bracket the OS overlays on the left edge,
     rows ~379-720, columns 0-12) -> replaced with the page background from
     column 18 of the same row. It sits over empty page margin, never over a card.

Run:  py captures/process_captures.py
"""
import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
REPO = PROJECT.parent.parent
PLAY = REPO / "marketing" / "play-store-2026-09" / "raw-captures"
# The exploration pass of the 25 Sep 2026 capture session (same device, same day).
EXPLORE = Path("C:/Users/840G8~1/AppData/Local/Temp/claude/c--Users-840-g8-Desktop-Projects-help24/"
               "205a52af-9783-4fe2-b39f-355a9986810d/scratchpad/explore")

SOURCES = [
    # name in film              source file                          what it is
    ("discover",                PLAY / "01-discover.png",            "Discover feed, scrolled one card past a Kampala listing"),
    ("discover-top",            EXPLORE / "CANDIDATE-discover-top.png", "Discover feed at top; ONLY rows 1140-1194 (Kitchen card's top edge) are used"),
    ("discover-scroll1",        EXPLORE / "04-discover-scroll1.png", "Discover feed, further down"),
    ("discover-scroll2",        EXPLORE / "05-discover-scroll2.png", "Discover feed, further down again"),
    ("post-composer",           PLAY / "02-post.png",                "Post composer step 1: Request / Offer / Job"),
    ("myposts",                 EXPLORE / "21-myposts-s4.png",       "Activity > My posts, Emergency Dog Trainer card"),
    ("notifications",           EXPLORE / "16-notifications.png",    "Notifications, incl. application to Emergency Dog Trainer"),
    ("detail-top",              EXPLORE / "CLEAN-postdetail.png",    "Post detail: Emergency Dog Trainer, top"),
    ("detail-scrolled",         EXPLORE / "23-secure-banner.png",    "Post detail scrolled: Pay securely through Help24 card"),
    ("secure",                  PLAY / "03-secure-service.png",      "Secure this service, IDLE (nothing paid)"),
    ("chat",                    PLAY / "05-messages.png",            "Chat pinned to Emergency Dog Trainer, Arrived card"),
    ("job-status",              PLAY / "04-job-status.png",          "Job status: Payment + Completion trackers"),
    ("history-work",            PLAY / "06-service-records.png",     "Service History > My Work"),
    ("history-services",        EXPLORE / "29-service-records.png",  "Service History > My Services"),
]

STATUS_H = 84
SAMPLE_ROW = 80
EDGE_ROWS = (360, 740)
EDGE_COLS = 16
EDGE_REF_COL = 18


def has_edge_handle(a):
    strip = a[EDGE_ROWS[0]:EDGE_ROWS[1], 0:12].mean(axis=(1, 2))
    ref = a[EDGE_ROWS[0]:EDGE_ROWS[1], 20].mean(axis=1)
    return int(((ref - strip) > 6).sum()) > 20


def process(src, dst):
    a = np.asarray(Image.open(src).convert("RGB")).copy()
    assert a.shape[:2] == (2400, 1080), f"{src.name}: unexpected size {a.shape}"
    report = {}
    # 1. status bar band
    a[0:STATUS_H] = a[SAMPLE_ROW][None, :, :]
    report["status_bg"] = "#%02X%02X%02X" % tuple(int(v) for v in a[SAMPLE_ROW, 540])
    # 2. edge handle
    if has_edge_handle(a):
        r0, r1 = EDGE_ROWS
        a[r0:r1, 0:EDGE_COLS] = a[r0:r1, EDGE_REF_COL][:, None, :]
        report["edge_handle_removed"] = True
    Image.fromarray(a).save(dst, optimize=True)
    return report


def main():
    raw_dir = HERE / "raw"
    out_dir = HERE / "processed"
    pub_dir = PROJECT / "remotion" / "public" / "screens"
    for d in (raw_dir, out_dir, pub_dir):
        d.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name, src, what in SOURCES:
        raw_copy = raw_dir / f"{name}.png"
        shutil.copyfile(src, raw_copy)
        rep = process(src, out_dir / f"{name}.png")
        shutil.copyfile(out_dir / f"{name}.png", pub_dir / f"{name}.png")
        manifest.append({"name": name, "source": str(src), "what": what, **rep})
        print(f"{name:18s} {rep}")
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=1))


if __name__ == "__main__":
    main()
