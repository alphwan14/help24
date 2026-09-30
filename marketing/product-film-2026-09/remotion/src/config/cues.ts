import { bar, beat, BREAK_1, BREAK_2, BREAK_3, DROP_1, DROP_3, MUSIC_END, MUSIC_LAST_HIT } from './timing';

/**
 * The cue sheet: every event in the film, as a frame, derived from the beat grid.
 * Accents land ON the beat (or a frame early), never after it.
 *
 *   beat(k)  = 15 + 18k          bar(n) = 72n - 3
 *   bars: 1=69  2=141  3=213  4=285  5=357  6=429  7=501(break)  8=573(drop)
 *         9=645 10=717 11=789 12=861 13=933 14=1005 15=1077 16=1149(break)
 *        17=1221 18=1293 19=1365 20=1437 21=1509 22=1581(break) 23=1653(drop) 24=1725
 */
export const CUE = {
  /* ---------- 0. The mark (bar 0) ---------- */
  barLeft: beat(0), //   15  left ink bar lands (it starts growing on frame 0)
  barRight: beat(1), //  33  right ink bar lands
  crossbar: beat(2), //  51  amber crossbar joins them

  /* ---------- 1. Discover (bars 1-2) ---------- */
  open: bar(1) - 6, //         63  the mark opens: bars become the phone's edges, crossbar the All chip
  opened: bar(1) + 30, //      99  the Discover screen has bloomed out of the chip
  wide: bar(1) + 36, //        105 camera settled on the phone
  flick1: bar(1) + 48, //      117 first flick through the feed
  flick2: beat(8), //          159 second flick
  capDiscover: bar(2), //      141 "Find help nearby."
  fabDown: bar(3) - 14, //     199 +Post pressed
  fabUp: bar(3) - 8, //        205 (release)

  /* ---------- 2. Ask (bar 3) ---------- */
  composerIn: bar(3) - 8, //   205 composer rises
  capAsk: bar(3) + 8, //       221 "Or ask for what you need."
  requestDown: beat(13), //    249 Request a Service pressed
  requestUp: beat(13) + 6, //  255 (release)
  toMyPosts: beat(13) + 10, // 259 card -> the Emergency Dog Trainer card (container transform)

  /* ---------- 3. The request (bars 4-6) ---------- */
  myPostsSettled: bar(4) + 6, // 291 the card has landed in My posts
  cardDown: beat(18), //         339 the request card is opened
  cardUp: beat(18) + 6, //       345 (release)
  toDetail: beat(18) + 8, //     347 card -> detail screen (title carried)
  detailSettled: bar(5) + 24, // 381 the request is open
  scroll1: beat(21) + 3, //      396 detail scrolls toward the protection card
  scroll2: beat(24) - 6, //      441 ... on to "Pay securely through Help24"

  /* ---------- 4. Decision (bar 7 - the first break) ---------- */
  dusk: BREAK_1 - 6, //      495 the room starts to darken
  ratchet1: beat(28), //     519 three stepped chords -> three camera steps
  ratchet2: beat(29), //     537 second chord, second step
  ratchet3: beat(30), //     555 third chord, third step
  secureDown: DROP_1 - 12, // 561 "Secure Service - KES 2,545" pressed
  secureUp: DROP_1 - 4, //   569 (release)

  /* ---------- 5. Secure this service (bars 8-11) ---------- */
  toSecure: DROP_1 - 4, //       569 detail -> secure; the amount flies to "Total to secure"
  secureSettled: DROP_1 + 26, // 599 the amount has landed
  capSecure: bar(8) + 30, //     603 "Secure the service."
  readBreakdown: bar(9) - 6, //  639 camera -> the breakdown
  readNote: bar(10) - 6, //      711 camera -> "held securely ... only released when the job is completed"
  capSecureSub: bar(10) + 2, //  719 "Your payment is held until you approve the work."
  pullBack: bar(11) + 6, //      795 camera eases back from the note
  capSecureOut: bar(12) - 18, // 843 copy leaves
  dawn: bar(12) - 28, //         833 the room lightens again

  /* ---------- 6. Talk it through (bars 12-15) ---------- */
  toChat: bar(12) - 12, //   849 secure -> chat; the job title flies into the pinned banner
  capChat: beat(48) + 12, // 891 "Talk it through."
  m2: beat(49), //           897 reply arrives
  m3: bar(13), //            933 sent
  m4: beat(53), //           969 "Okay I'll there in a few minutes"
  m5: beat(57), //           1041 Arrived 12:11 PM (a pause first: time passes)
  m6: bar(15), //            1077 "I've arrived at the location."

  /* ---------- 7. Arrived (bar 16 - the second break) ---------- */
  arrivedPush: BREAK_2 - 18, // 1131 camera moves in on Arrived; the thread recedes
  toTrackers: BREAK_2 + 42, //  1191 camera trucks right, off the phone

  /* ---------- 8. Progress (bars 17-18) ---------- */
  trackersIn: BREAK_2 + 54, // 1203 the two trackers rise into place
  rowsPayment: bar(17) + 6, // 1227 tracker rows reveal, in order
  rowsCompletion: bar(17) + 24, // 1245 ... then Completion's
  capProgress: bar(17) + 18, //    1239 "Know where every job stands."
  capProgressOut: bar(18) + 36, // 1329 copy leaves

  /* ---------- 9. Record (bars 19-21) ---------- */
  toHistory: bar(19) - 30, //   1335 camera trucks right to the phone again
  historyRows: bar(19) - 8, //  1357 Service History settles in, row by row
  capRecord: bar(19) + 6, //    1371 "Every job, on record."
  capRecordOut: bar(21) - 24, // 1485 copy leaves
  towardChip: bar(21), //       1509 camera drifts toward "Payment protected"

  /* ---------- 10. Lift (bar 22 - the third break) ---------- */
  chipLift: BREAK_3, //         1581 "Payment protected" lifts off
  chipMorph: BREAK_3 + 12, //   1593 its words go; it becomes the crossbar
  barsIn: BREAK_3 + 40, //      1621 the two ink bars close in...
  markComplete: DROP_3, //      1653 ...and meet on the downbeat

  /* ---------- 11. Brand (bars 23-24) ---------- */
  tile: DROP_3 + 18, //          1671 the mark becomes the app icon
  lockup: DROP_3 + 30, //        1683 wordmark
  tagline1: bar(24), //          1725 "Get help."
  tagline2: beat(97), //         1761 "Get it done."
  lastHit: MUSIC_LAST_HIT, //    1779 the track's last hit
  musicEnd: MUSIC_END, //        1783 the track ends; the end card holds in silence to 60.5 s
};

export const BREAKS = { BREAK_1, BREAK_2, BREAK_3 };
