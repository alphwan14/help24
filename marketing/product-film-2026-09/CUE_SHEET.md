# Help24 product film: cue sheet

Generated from `remotion/src/config/cues.ts` by `node tools/cuesheet.js`. Do not edit by hand.

The music runs at 100 BPM, so at 30 fps one beat is 18 frames and one bar is 72. Beat 1 of bar *n* falls on frame 72*n* − 3.
Bars 7, 16 and 22 are the one-bar breaks, and bars 8, 17 and 23 are the returns.
Each grid position is the nearest beat, with an offset in frames: **−2f** means the event lands two frames before that beat.

| Frame | Time | Bar · beat | Cue | What happens |
|---:|---:|---|---|---|
| | | | **0. The mark (bar 0)** | |
| 15 | 0.50 s | 0 · 2 | `barLeft` | left ink bar lands (it starts growing on frame 0) |
| 33 | 1.10 s | 0 · 3 | `barRight` | right ink bar lands |
| 51 | 1.70 s | 0 · 4 | `crossbar` | amber crossbar joins them |
| | | | **1. Discover (bars 1-2)** | |
| 63 | 2.10 s | 1 · 1 (-6f) | `open` | the mark opens: bars become the phone's edges, crossbar the All chip |
| 99 | 3.30 s | 1 · 3 (-6f) | `opened` | the Discover screen has bloomed out of the chip |
| 105 | 3.50 s | 1 · 3 | `wide` | camera settled on the phone |
| 117 | 3.90 s | 1 · 4 (-6f) | `flick1` | first flick through the feed |
| 141 | 4.70 s | 2 · 1 | `capDiscover` | "Find help nearby." |
| 159 | 5.30 s | 2 · 2 | `flick2` | second flick |
| 199 | 6.63 s | 2 · 4 (+4f) | `fabDown` | +Post pressed |
| 205 | 6.83 s | 3 · 1 (-8f) | `fabUp` | (release) |
| | | | **2. Ask (bar 3)** | |
| 205 | 6.83 s | 3 · 1 (-8f) | `composerIn` | composer rises |
| 221 | 7.37 s | 3 · 1 (+8f) | `capAsk` | "Or ask for what you need." |
| 249 | 8.30 s | 3 · 3 | `requestDown` | Request a Service pressed |
| 255 | 8.50 s | 3 · 3 (+6f) | `requestUp` | (release) |
| 259 | 8.63 s | 3 · 4 (-8f) | `toMyPosts` | card -> the Emergency Dog Trainer card (container transform) |
| | | | **3. The request (bars 4-6)** | |
| 291 | 9.70 s | 4 · 1 (+6f) | `myPostsSettled` | the card has landed in My posts |
| 339 | 11.30 s | 4 · 4 | `cardDown` | the request card is opened |
| 345 | 11.50 s | 4 · 4 (+6f) | `cardUp` | (release) |
| 347 | 11.57 s | 4 · 4 (+8f) | `toDetail` | card -> detail screen (title carried) |
| 381 | 12.70 s | 5 · 2 (+6f) | `detailSettled` | the request is open |
| 396 | 13.20 s | 5 · 3 (+3f) | `scroll1` | detail scrolls toward the protection card |
| 441 | 14.70 s | 6 · 2 (-6f) | `scroll2` | ... on to "Pay securely through Help24" |
| | | | **4. Decision (bar 7 - the first break)** | |
| 495 | 16.50 s | 7 · 1 (-6f) | `dusk` | the room starts to darken |
| 519 | 17.30 s | 7 · 2 | `ratchet1` | three stepped chords -> three camera steps |
| 537 | 17.90 s | 7 · 3 | `ratchet2` | second chord, second step |
| 555 | 18.50 s | 7 · 4 | `ratchet3` | third chord, third step |
| 561 | 18.70 s | 7 · 4 (+6f) | `secureDown` | "Secure Service - KES 2,545" pressed |
| 569 | 18.97 s | 8 · 1 (-4f) | `secureUp` | (release) |
| | | | **5. Secure this service (bars 8-11)** | |
| 569 | 18.97 s | 8 · 1 (-4f) | `toSecure` | detail -> secure; the amount flies to "Total to secure" |
| 599 | 19.97 s | 8 · 2 (+8f) | `secureSettled` | the amount has landed |
| 603 | 20.10 s | 8 · 3 (-6f) | `capSecure` | "Secure the service." |
| 639 | 21.30 s | 9 · 1 (-6f) | `readBreakdown` | camera -> the breakdown |
| 711 | 23.70 s | 10 · 1 (-6f) | `readNote` | camera -> "held securely ... only released when the job is completed" |
| 719 | 23.97 s | 10 · 1 (+2f) | `capSecureSub` | "Your payment is held until you approve the work." |
| 795 | 26.50 s | 11 · 1 (+6f) | `pullBack` | camera eases back from the note |
| 833 | 27.77 s | 11 · 3 (+8f) | `dawn` | the room lightens again |
| 843 | 28.10 s | 11 · 4 | `capSecureOut` | copy leaves |
| | | | **6. Talk it through (bars 12-15)** | |
| 849 | 28.30 s | 11 · 4 (+6f) | `toChat` | secure -> chat; the job title flies into the pinned banner |
| 891 | 29.70 s | 12 · 3 (-6f) | `capChat` | "Talk it through." |
| 897 | 29.90 s | 12 · 3 | `m2` | reply arrives |
| 933 | 31.10 s | 13 · 1 | `m3` | sent |
| 969 | 32.30 s | 13 · 3 | `m4` | "Okay I'll there in a few minutes" |
| 1041 | 34.70 s | 14 · 3 | `m5` | Arrived 12:11 PM (a pause first: time passes) |
| 1077 | 35.90 s | 15 · 1 | `m6` | "I've arrived at the location." |
| | | | **7. Arrived (bar 16 - the second break)** | |
| 1131 | 37.70 s | 15 · 4 | `arrivedPush` | camera moves in on Arrived; the thread recedes |
| 1191 | 39.70 s | 16 · 3 (+6f) | `toTrackers` | camera trucks right, off the phone |
| | | | **8. Progress (bars 17-18)** | |
| 1203 | 40.10 s | 16 · 4 | `trackersIn` | the two trackers rise into place |
| 1227 | 40.90 s | 17 · 1 (+6f) | `rowsPayment` | tracker rows reveal, in order |
| 1239 | 41.30 s | 17 · 2 | `capProgress` | "Know where every job stands." |
| 1245 | 41.50 s | 17 · 2 (+6f) | `rowsCompletion` | ... then Completion's |
| 1329 | 44.30 s | 18 · 3 | `capProgressOut` | copy leaves |
| | | | **9. Record (bars 19-21)** | |
| 1335 | 44.50 s | 18 · 3 (+6f) | `toHistory` | camera trucks right to the phone again |
| 1357 | 45.23 s | 19 · 1 (-8f) | `historyRows` | Service History settles in, row by row |
| 1371 | 45.70 s | 19 · 1 (+6f) | `capRecord` | "Every job, on record." |
| 1485 | 49.50 s | 20 · 4 (-6f) | `capRecordOut` | copy leaves |
| 1509 | 50.30 s | 21 · 1 | `towardChip` | camera drifts toward "Payment protected" |
| | | | **10. Lift (bar 22 - the third break)** | |
| 1581 | 52.70 s | 22 · 1 | `chipLift` | "Payment protected" lifts off |
| 1593 | 53.10 s | 22 · 2 (-6f) | `chipMorph` | its words go; it becomes the crossbar |
| 1621 | 54.03 s | 22 · 3 (+4f) | `barsIn` | the two ink bars close in... |
| 1653 | 55.10 s | 23 · 1 | `markComplete` | ...and meet on the downbeat |
| | | | **11. Brand (bars 23-24)** | |
| 1671 | 55.70 s | 23 · 2 | `tile` | the mark becomes the app icon |
| 1683 | 56.10 s | 23 · 3 (-6f) | `lockup` | wordmark |
| 1725 | 57.50 s | 24 · 1 | `tagline1` | "Get help." |
| 1761 | 58.70 s | 24 · 3 | `tagline2` | "Get it done." |
| 1779 | 59.30 s | 24 · 4 | `lastHit` | the track's last hit |
| 1783 | 59.43 s | 24 · 4 (+4f) | `musicEnd` | the track ends; the end card holds in silence to 60.5 s |
