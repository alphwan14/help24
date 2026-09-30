# Help24: product film (September 2026)

This is a 60-second product film of the Help24 Android app. It follows one real job, **Emergency Dog Trainer** (KES 2,500), from the marketplace to a finished record, and it is cut to the supplied marketing track.

The film is built in [Remotion](https://remotion.dev). Every scene, cue, line of copy and screenshot is an editable source file, and the film re-renders deterministically.

| File | What it is |
|---|---|
| `renders/help24-film-master.mp4` | **The film.** 16:9, 1920×1080, 30 fps, H.264 CRF 15 (BT.709), AAC 320k, 60.5 s |
| `renders/help24-film-vertical.mp4` | The same film cut for 9:16 (1080×1920), for Reels, Shorts, Status and TikTok |
| `renders/help24-film-preview.mp4` | A lighter copy of the master (1280×720, about 7 MB), for messaging and review |
| `renders/poster-*.png` | Stills for thumbnails and decks: discover, secure, chat, trackers and end card, plus vertical secure and end card |
| `renders/review/` | Contact sheets of the final cuts, one tile every 0.5 s |
| `STORYBOARD.md` | The scene list, timing against the music, transitions, type and visual system |
| `CUE_SHEET.md` | Every cue in the film: frame, time and bar/beat. It is generated from the source |
| `audio/` | The source track, a lossless decode, and the analysis the timing is built on |
| `captures/raw/` | The untouched ADB captures used, copied from the 25 Sep 2026 session |
| `captures/processed/` | The same captures with OS chrome cleaned (status bar, edge-panel handle), and nothing else |
| `remotion/` | The editable film |

## Rendering

```bash
cd remotion
npm install
npx remotion studio src/index.ts        # scrub both formats live

# master, 16:9
npx remotion render src/index.ts Help24Film ../renders/_raw-master.mp4 \
  --image-format=png --crf=15 --x264-preset=slow --color-space=bt709 --audio-bitrate=320k
# vertical, 9:16
npx remotion render src/index.ts Help24Film-Vertical ../renders/_raw-vertical.mp4 \
  --image-format=png --crf=15 --x264-preset=slow --color-space=bt709 --audio-bitrate=320k

# then finalize each one (lossless) and prove the sync
node tools/finalize.js ../renders/_raw-master.mp4 ../renders/help24-film-master.mp4
node tools/finalize.js ../renders/_raw-vertical.mp4 ../renders/help24-film-vertical.mp4
py ../audio/verify_sync.py ../renders/help24-film-master.mp4      # expect ~0 ms at every point
```

On an 8-thread laptop, a full render takes about 7–8 minutes per format. Motion blur is the main cost (see below).

**Why the finalize step exists.** Remotion's AAC encoder puts 2048 samples of priming at the start of the audio track but writes no edit list to skip them. As a result, every player runs the music 42.7 ms (about 1.3 frames) behind the picture.

`tools/finalize.js` shifts the audio back by exactly that amount, without re-encoding, so the muxer writes the edit list. It also moves the index to the front of the file (`+faststart`) so the file can start playing before it has fully downloaded.

On both finals, `audio/verify_sync.py` measured the soundtrack against the reference WAV at 2, 19, 40 and 55 s:

| | Before finalize | After finalize |
|---|---|---|
| Audio offset | +42.33 ms | −0.33 ms |

## How the source is organised

```
remotion/src/
  config/timing.ts        the music's grid: bar() / beat(); every cue is written against it
  config/cues.ts          the cue sheet: every event in the film, one named frame each
  config/copy.ts          every word on screen
  config/screens.ts       measured geometry of every real capture (rects in capture pixels)
  config/theme.ts         colour and type (from the app's tokens.dart)
  config/format.ts        16:9 / 9:16: frame sizes and caption layout
  scenes/choreography.ts  stage layout, camera poses and track per format, day/night, motion-blur policy
  screens/*.tsx           each real screen assembled from slices of its capture, with its own motion
  components/*.tsx        device, captions, status bar, tap feedback, brand mark, motion blur
  Film.tsx                the assembly; Root.tsx registers the two compositions
remotion/tools/
  review.js               contact sheets and full-size frames from any render (how the film was reviewed)
  cuesheet.js             regenerates ../CUE_SHEET.md from cues.ts
  blurstats.js            motion-blur samples per frame, per format (checks the blur policy, estimates render time)
  finalize.js             lossless delivery pass: removes AAC priming from the timeline, +faststart
audio/
  analyze_audio.py        tempo, beats, onsets, sections   (numpy only)
  grid_fit.py             the strict 100 BPM grid and the bar-by-bar drum map
  verify_sync.py          proves a render's soundtrack sits where the film was choreographed
```

* **To change a line of copy:** edit `config/copy.ts`.
* **To retime a moment:** edit `config/cues.ts`, then run `node tools/cuesheet.js`. Cues are expressed in bars and beats, so they stay on the music.
* **To replace a screenshot:**
  1. Put the capture in `captures/raw/` and add it to `captures/process_captures.py`.
  2. Run the script.
  3. Re-measure that screen's rects in `config/screens.ts`. `captures/measure.py` has helpers for rows, columns, scroll offsets and bounding boxes.
* **To swap the music:**
  1. Decode it to 16-bit WAV.
  2. Run `audio/analyze_audio.py` and `audio/grid_fit.py`.
  3. Update `FIRST_BEAT_S`, `BPM` and `DOWNBEAT_PHASE` in `config/timing.ts`. If the new track's structure differs, also update the three break/drop bars.
* **To add another aspect ratio (1:1, 4:5):**
  1. Add a format to `config/format.ts` and a composition to `Root.tsx`.
  2. Add a stage layout and pose table in `scenes/choreography.ts`.

  The shot list (`cameraKeys`) is shared across formats, so a new format only needs poses. The screens, cues and copy are reused unchanged.

**Motion blur.** The film uses a centred 180° shutter (`components/MotionBlur.tsx`). It is applied only on frames where something actually travels:

* camera moves;
* feed flicks, scrolls and the rising composer;
* shared-element flights and the chat's stack shifts.

Enough samples are taken that the copies within one frame sit no more than about 3 px apart, so motion reads as a smear rather than an echo. Still frames get no blur. The backdrop and the type are never blurred.

## What was captured, and the rules the film was built under

All UI in the film is the live Android build (`com.help24.help24`). It was captured over ADB on a Galaxy S20+ (1080×2400) on 25 Sep 2026, during the Play Store capture session and its exploration pass. No device was connected for this build, so no new captures were taken. `captures/manifest.json` lists every source file.

* **Every pixel inside the phone is the real app.** Screens are *assembled* from rectangles of the real captures so they can move: bubbles arriving, rows revealing, cards expanding. The resting state of each screen is the capture's own layout. Nothing inside the app was redrawn, recoloured or re-typed.
* **The only edits are to OS chrome.** There is one consistent status bar (10:30), and the Samsung edge-panel handle is removed from the captures that had it.
* **Two long screens are stitched from consecutive captures of the same list:** the Discover feed and the request's detail page. This lets them scroll genuinely. The seams sit in the empty gaps between cards, and each offset was verified to a mean pixel difference below 1 (`captures/measure.py offset`).
* **No payment is shown.** *Secure this service* appears in its idle state, and *Pay KES 2,545 Securely* is never pressed. No M-Pesa prompt, success screen, receipt body, transaction ID or balance appears.
* **The trackers are shown exactly as captured** (Payment Required / In Progress). Their rows reveal in order, but no state is advanced. Only the cards are shown, so the other job named on that screen never appears beside the Emergency Dog Trainer story.
* **The Service History figures are one account's own in-app values.** "6 completed jobs" and "KES 54,300" are not platform statistics, and the film never captions them.
* **The copy says what the app says.** The protection line ("Your payment is held until you approve the work") restates the app's own post-detail copy. The app's `PaymentCopy` notes that release requires the client's approval.
* **People:** names appear as they do in the app. The only face photo in the film is the account owner's own, per the Play Store capture notes. It is never the subject of a shot.
