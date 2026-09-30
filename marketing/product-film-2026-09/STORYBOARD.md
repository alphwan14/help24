# Help24 — product film storyboard

**Master:** 1920×1080, 30 fps, 60.5 s (1815 frames), with `audio/help24_audiomarketing.source.mp4`.

**Vertical cut:** 1080×1920. It uses the same screens, cues and copy with its own framing:

* the copy sits in a band of paper across the top, which turns to night in the trust scene;
* the two trackers are stacked, so they read top to bottom;
* the end card is quieter.
**Spine:** one real job, followed through the product: **Emergency Dog Trainer**, KES 2,500
(KES 2,545 to secure). Every screen is a real ADB capture of the live Android build (25 Sep 2026).
The job's title, and later its amount, is the element carried from one screen to the next.

## The music (measured in `audio/`)

| | |
|---|---|
| Tempo | **100.00 BPM**, beat = 0.6 s = **18 frames**, bar = 2.4 s = **72 frames** |
| Grid | beat *k* at 0.5 s + 0.6·k; bar downbeats where k ≡ 3 (mod 4): 2.3, 4.7, 7.1 … 59.9 s |
| Vocals | none (flat harmonic lines, no gliding pitch) |
| Breaks | one-bar drop-outs at **16.7, 38.3, 52.7 s**, each a stepped build into a full-band return at **19.1, 40.7, 55.1 s** |
| End | the track is trimmed: the last hit is on **59.3 s**, the audio stops at **59.42 s**. The end card holds in silence. |

The film cuts on bars, not on beats. The breaks are where the film breathes, and the returns are where it moves forward.

## Acts and scenes

| # | Time (s) | Bars | Scene | What the viewer should get |
|---|---|---|---|---|
| 0 | 0.0–2.3 | 0 | **Mark.** The two ink bars rise on beats 0 and 1, and the amber crossbar joins them on beat 2. | This is Help24. |
| 1 | 2.3–7.1 | 1–2 | **Discover.** The mark unfolds into the phone. Its two ink bars travel out and stretch into the device's two edges, while the crossbar (the exact size and colour of the selected *All* chip) settles into that chip. The app blooms out of the chip, and the stitched real feed scrolls through two flicks. | Every kind of help, nearby: requests *and* offers. |
| 2 | 7.1–9.5 | 3 | **Ask.** *+ Post* is pressed, and *What would you like to do?* rises. *Request a Service* is pressed. | You can ask, not just browse. |
| 3 | 9.5–16.7 | 4–6 | **The request.** The pressed card becomes the *Emergency Dog Trainer* card in My posts, which opens into its detail screen (title shared). The detail scrolls to *Pay securely through Help24*. | This is one real job we will follow. |
| 4 | 16.7–19.1 | 7 (break) | **Decision.** The room darkens. On the three stepped chords the camera ratchets in on the protection card, and *Secure Service · KES 2,545* is pressed. | The turn toward trust. |
| 5 | 19.1–28.7 | 8–11 | **Secure this service.** The amount *KES 2,545* flies from the button into *Total to secure*. The camera reads the breakdown, then settles on *"Your payment is held securely and only released when the job is completed."* The Pay button is **never pressed**. | Payment is held, and released when you approve the work. |
| 6 | 28.7–38.3 | 12–15 | **Talk it through.** The job title flies into the chat's pinned banner. Replies arrive with an irregular rhythm: the question is answered, *"Okay I'll there in a few minutes"*, and then the real **Arrived 12:11 PM** card. | Customer and provider talk directly, in a thread tied to the job. |
| 7 | 38.3–40.7 | 16 (break) | **Arrived.** A still, close hold on the Arrived card. | They came. |
| 8 | 40.7–45.5 | 17–18 | **Progress.** The two real trackers are lifted out of the job-status screen: Payment (Required → Sent → Protected → Payout Pending → Payout Released) and Completion. The rows reveal in order, and **the states are not advanced.** | Every job has a visible, structured path. |
| 9 | 45.5–52.7 | 19–21 | **Record.** Service History → My Work: completed jobs, each with its payment state and a Receipt. | The work leaves a record. |
| 10 | 52.7–55.1 | 22 (break) | **Lift.** The last UI element, a real *Payment protected* chip, lifts off. Its words fade, and it becomes the amber crossbar. | Protection is the brand. |
| 11 | 55.1–60.5 | 23–24 | **Brand.** The two bars close in around the crossbar on the downbeat, and the mark becomes the app icon, then the lockup. *Get help. Get it done.* lands on the last beats, the music stops, and the card holds. | Help24. |

## Transitions (no fades to black, and no stock transitions)

* **Mark → phone**: the bars become the phone's edges, and the crossbar becomes the *All* chip the app blooms from. The brand literally opens the product.
* **Composer card → My posts card → detail screen**: container transforms, the Material pattern for "this became that".
* **Detail → Secure**: a shared X axis with the **amount** flown as the shared element.
* **Secure → Chat**: a shared X axis with the **job title** flown into the pinned banner.
* **Chat → trackers → history**: the device steps aside and real UI cards are lifted out (a spatial move, not a cut).
* **History → mark**: the *Payment protected* chip becomes the crossbar, mirroring the opening.

## Type

Inter, the typeface the app and website bundle. One headline style (64 px, 600, −0.025 em), and one
subline style that is used once, in the trust scene. Type is placed in empty space beside the UI and never
over UI text. It rises 16 px while fading in over 15 frames on an ease-out, and exits in 9 frames.

1. *Find help nearby.*
2. *Or ask for what you need.*
3. *Secure the service.* / *Your payment is held until you approve the work.*
4. *Talk it through.*
5. *Know where every job stands.*
6. *Every job, on record.*
7. End card: the Help24 lockup, then *Get help. Get it done.*

## Visual system

* **Paper** `#F2EFE9` stage with a soft warm light and fine grain. **Ink** `#0F1215` is used only for the trust scene: the
  room darkens and the lit screen becomes the only light source. There are no glows, locks or shields added.
* **Amber** `#E8A33D`, the brand crossbar, is the one accent. It appears as the mark, the All chip, and the final chip.
* Slim ink device body with real status bar/gesture pill. The camera works in capture pixels: the wide shot is about 0.4×,
  close shots about 1.0× (native capture resolution, never soft), and the macro at most about 1.25×.
* Framing: with no words on screen the phone is centred. The camera moves it aside only to make room for a line of copy, so every lateral move is motivated.
* Focus: a single window moves from card to card. By day the rest recedes to paper. In the dark room it dims, like a lamp on one card.
* Motion blur: a centred 180° shutter, applied only on frames where the picture actually travels (camera trucks, ratchets, the composer rising, shared-element flights). The backdrop is never blurred.
* Motion: ease-out entrances `(0.23, 1, 0.32, 1)`, on-screen moves `(0.2, 0, 0, 1)`, camera `(0.65, 0, 0.35, 1)`,
  bounce only on chat bubbles (≈0.1) and the Arrived card, and zero overshoot on the camera.

## Honesty rules the film is built under

* Every pixel inside the device is the real app. The only edits are to OS chrome: a clean status bar, and the Samsung edge-panel handle removed.
* No payment is shown being made. The *Pay KES 2,545 Securely* button is never pressed, and no M-Pesa prompt,
  success state, receipt body, transaction ID or balance appears.
* The trackers are shown in their real state (Payment Required / In Progress). Reveals are sequential, and
  no state is advanced.
* The figures on Service History are one account's own values, not platform statistics, and are not captioned as such.
