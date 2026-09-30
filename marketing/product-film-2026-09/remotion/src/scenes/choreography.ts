import { CUE } from '../config/cues';
import { Format } from '../config/format';
import { bar, BREAK_1 } from '../config/timing';
import { E, Key, track, trackObj } from '../lib/anim';
import { discoverScroll } from '../screens/Discover';
import { composerRise, detailScroll } from '../screens/Request';
import { stackOffset } from '../screens/Chat';

/**
 * The stage is laid out in capture pixels, the way the story travels: the
 * phone (Discover -> Chat), the two trackers lifted out beside it, the phone
 * again (Service History) and the mark its last chip becomes. The camera
 * moves through it, so every transition between them is a real spatial move.
 *
 * landscape: trackers side by side to the right of the phone (a truck right),
 *            History below them (a tilt down).
 * portrait:  trackers stacked (they are read top to bottom), History below.
 * In both, each place is far enough from the next that no frame catches its neighbour.
 */
export type Stage = {
  devA: { x: number; y: number };
  trackers: { x: number; y: number; gap: number; stacked: boolean };
  devB: { x: number; y: number };
};

const STAGES: Record<Format, Stage> = {
  landscape: {
    devA: { x: 0, y: 0 },
    trackers: { x: 1650, y: 820, gap: 88, stacked: false },
    devB: { x: 2200, y: 1900 },
  },
  portrait: {
    devA: { x: 0, y: 0 },
    trackers: { x: 1650, y: 820, gap: 88, stacked: true },
    devB: { x: 1605, y: 2300 },
  },
};
export const stageOf = (format: Format) => STAGES[format];

/** Where the opening mark sits: its crossbar is exactly the All chip (DISCOVER.allChip). */
export const MARK_OPEN = { cx: 114.5, cy: 478, unit: 112 / 12 };
/** Where the closing mark sits: its crossbar is exactly the Payment protected chip. */
export const markEndOf = (format: Format) => {
  const d = STAGES[format].devB;
  return { cx: d.x + 87 + 180, cy: d.y + 2179 + 34, unit: 68 / 12 };
};

/**
 * Camera: the stage point (cx, cy) is placed at frame position (0.5+ox, 0.5+oy),
 * with `span` stage pixels filling the frame height. In landscape span 1080 is
 * native capture resolution; in portrait it is span 1920.
 */
export type Cam = { cx: number; cy: number; span: number; ox: number; oy: number };
type Poses = Record<string, Cam>;
const cam = (cx: number, cy: number, span: number, ox = 0, oy = 0): Cam => ({ cx, cy, span, ox, oy });

/*
 * Landscape framing rules:
 *  - with no words on screen the phone is centred; the camera moves it aside
 *    only to make room for a line of copy, so every lateral move is motivated;
 *  - anything the viewer must read is framed at span <= ~1500 (>= 0.72x native);
 *  - never tighter than span ~880 (1.23x) - past that the capture goes soft.
 */
const landscapePoses = (): Poses => {
  const S = STAGES.landscape;
  const trkCx = S.trackers.x + 990 + S.trackers.gap / 2;
  const end = markEndOf('landscape');
  return {
    mark0: cam(MARK_OPEN.cx, MARK_OPEN.cy, 2760),
    mark: cam(MARK_OPEN.cx, MARK_OPEN.cy, 2620),
    phone: cam(540, 1200, 2700),
    feedRight: cam(540, 1230, 2330, 0.16),
    feedPush: cam(540, 1300, 2060, 0.155),
    composer: cam(540, 880, 1760, 0.15),
    myposts: cam(540, 1263, 1260, 0.07),
    mypostsDrift: cam(540, 1263, 1170, 0.06),
    detailWide: cam(540, 1110, 2160),
    detailRead: cam(540, 1330, 1880),
    detailLow: cam(540, 1680, 1640),
    r1: cam(548, 1760, 1440),
    r2: cam(556, 1826, 1250),
    r3: cam(564, 1880, 1090),
    secure: cam(540, 950, 2150, 0.17),
    breakdown: cam(540, 700, 1120, 0.2),
    note: cam(540, 1300, 1090, 0.2),
    securePull: cam(540, 1050, 1950, 0.17),
    chatTop: cam(540, 1190, 2650, 0.16), // the whole thread: the job banner the title lands in
    chat: cam(540, 1470, 1900, 0.16),
    chatLow: cam(540, 1690, 1500, 0.16),
    chatCenter: cam(520, 1740, 1400),
    arrived: cam(350, 1792, 880),
    trackers: cam(trkCx, 1110, 1330, 0, 0.085),
    trackersPush: cam(trkCx, 1120, 1200, 0, 0.07),
    history: cam(S.devB.x + 540, S.devB.y + 1230, 2250, 0.155),
    historyRead: cam(S.devB.x + 540, S.devB.y + 1420, 1900, 0.15),
    historyLow: cam(S.devB.x + 420, S.devB.y + 1960, 1500, 0.04),
    endMark: cam(end.cx, end.cy, 1700, 0, -0.02),
    endLockup: cam(end.cx, end.cy + 150, 3500, 0, -0.03),
    endHold: cam(end.cx, end.cy + 150, 3560, 0, -0.03),
  };
};

/*
 * Portrait framing rules (1080 x 1920, watched on a phone):
 *  - UI near native scale (span ~1900-2100) so it can be read on a phone;
 *  - when a line of copy is up it sits in a paper band across the top, so the
 *    subject is framed low (oy ~0.1) and nothing that matters sits under the band;
 *  - the phone is never wider than the frame (span >= ~1900).
 */
const portraitPoses = (): Poses => {
  const S = STAGES.portrait;
  const trkCx = S.trackers.x + 495;
  const trkCy = S.trackers.y + (572 + S.trackers.gap + 493) / 2;
  const end = markEndOf('portrait');
  return {
    mark0: cam(MARK_OPEN.cx, MARK_OPEN.cy, 3700),
    mark: cam(MARK_OPEN.cx, MARK_OPEN.cy, 3500),
    phone: cam(540, 1200, 2640),
    feedRight: cam(540, 1060, 2120, 0, 0.12),
    feedPush: cam(540, 1250, 1980, 0, 0.12),
    composer: cam(540, 900, 2000, 0, 0.14),
    myposts: cam(540, 1263, 1960),
    mypostsDrift: cam(540, 1263, 1880),
    detailWide: cam(540, 1150, 2640),
    detailRead: cam(540, 1330, 2250),
    detailLow: cam(540, 1680, 2100),
    r1: cam(540, 1760, 2050),
    r2: cam(540, 1826, 1990),
    r3: cam(540, 1880, 1930),
    secure: cam(540, 1000, 2100, 0, 0.125),
    breakdown: cam(540, 711, 1960, 0, 0.1),
    note: cam(540, 1307, 1960, 0, 0.1),
    securePull: cam(540, 1000, 2100, 0, 0.125),
    chatTop: cam(540, 1000, 2400),
    chat: cam(540, 1520, 2050, 0, 0.1),
    chatLow: cam(540, 1660, 1960, 0, 0.1),
    chatCenter: cam(540, 1700, 1900),
    arrived: cam(350, 1792, 1560),
    trackers: cam(trkCx, trkCy, 1960, 0, 0.086),
    trackersPush: cam(trkCx, trkCy, 1880, 0, 0.086),
    history: cam(S.devB.x + 540, S.devB.y + 1100, 2250, 0, 0.1),
    historyRead: cam(S.devB.x + 540, S.devB.y + 1420, 2000, 0, 0.02),
    historyLow: cam(S.devB.x + 470, S.devB.y + 1900, 1900),
    endMark: cam(end.cx, end.cy, 2400, 0, -0.03),
    endLockup: cam(end.cx, end.cy + 200, 5600, 0, -0.03),
    endHold: cam(end.cx, end.cy + 200, 5700, 0, -0.03),
  };
};

/** One shot list for both formats: the same beats, framed per format. */
const cameraKeys = (P: Poses): Key<Cam>[] => [
  { f: 0, v: P.mark0 },
  { f: CUE.open, v: P.mark, ease: E.linear }, // a barely-there push while the mark builds
  { f: CUE.wide, v: P.phone, ease: E.cam }, // the mark unfolds; the camera centres the phone it became
  { f: CUE.capDiscover - 8, v: P.phone, ease: E.linear },
  { f: CUE.capDiscover + 24, v: P.feedRight, ease: E.cam }, // making room for the first line
  { f: CUE.flick2 - 2, v: P.feedRight, ease: E.linear },
  { f: CUE.fabDown, v: P.feedPush, ease: E.cam },
  { f: CUE.composerIn + 36, v: P.composer, ease: E.cam },
  { f: CUE.toMyPosts, v: P.composer, ease: E.linear },
  { f: CUE.toMyPosts + 34, v: P.myposts, ease: E.cam },
  { f: CUE.toDetail, v: P.mypostsDrift, ease: E.linear },
  // the card opens into the request; pull back with it (and keep the poster's photo small)
  { f: CUE.toDetail + 34, v: P.detailWide, ease: E.cam },
  { f: CUE.scroll1, v: P.detailWide, ease: E.linear },
  { f: CUE.scroll1 + 40, v: P.detailRead, ease: E.cam },
  { f: CUE.scroll2, v: P.detailRead, ease: E.linear },
  { f: BREAK_1, v: P.detailLow, ease: E.cam },
  // the three stepped chords of the break: three short pushes, each starting on its chord
  { f: CUE.ratchet1 - 2, v: P.detailLow, ease: E.linear },
  { f: CUE.ratchet1 + 12, v: P.r1, ease: E.push },
  { f: CUE.ratchet2 - 2, v: P.r1, ease: E.linear },
  { f: CUE.ratchet2 + 12, v: P.r2, ease: E.push },
  { f: CUE.ratchet3 - 2, v: P.r2, ease: E.linear },
  { f: CUE.ratchet3 + 12, v: P.r3, ease: E.push },
  { f: CUE.toSecure - 2, v: P.r3, ease: E.linear },
  // on the drop the new screen arrives and the camera steps back to take it in whole
  { f: CUE.toSecure + 24, v: P.secure, ease: E.move },
  { f: CUE.readBreakdown, v: P.secure, ease: E.linear },
  { f: CUE.readBreakdown + 34, v: P.breakdown, ease: E.cam },
  { f: CUE.readNote, v: P.breakdown, ease: E.linear },
  { f: CUE.readNote + 36, v: P.note, ease: E.cam },
  { f: CUE.pullBack, v: P.note, ease: E.linear },
  { f: CUE.pullBack + 40, v: P.securePull, ease: E.cam },
  { f: CUE.toChat, v: P.securePull, ease: E.linear },
  // first the whole thread, so the job title is seen landing in its pinned banner;
  // then one slow push in, down the conversation, while it unfolds
  { f: CUE.toChat + 26, v: P.chatTop, ease: E.cam },
  { f: CUE.capChat - 4, v: P.chatTop, ease: E.linear },
  { f: CUE.m4 + 6, v: P.chatLow, ease: E.cam },
  { f: CUE.m4 + 30, v: P.chatLow, ease: E.linear },
  { f: CUE.m5 + 4, v: P.chatCenter, ease: E.cam }, // words gone: the thread takes the centre
  { f: CUE.arrivedPush, v: P.chatCenter, ease: E.linear },
  { f: CUE.arrivedPush + 34, v: P.arrived, ease: E.cam },
  { f: CUE.toTrackers, v: P.arrived, ease: E.linear },
  { f: CUE.toTrackers + 46, v: P.trackers, ease: E.inOut },
  { f: CUE.toHistory - 2, v: P.trackersPush, ease: E.linear },
  { f: CUE.toHistory + 44, v: P.history, ease: E.inOut },
  { f: CUE.capRecord + 40, v: P.history, ease: E.linear },
  { f: CUE.capRecordOut, v: P.historyRead, ease: E.cam },
  { f: CUE.towardChip, v: P.historyRead, ease: E.linear },
  { f: CUE.chipLift + 6, v: P.historyLow, ease: E.cam },
  { f: CUE.barsIn - 4, v: P.endMark, ease: E.cam },
  { f: CUE.tile, v: P.endMark, ease: E.linear },
  { f: CUE.tagline1, v: P.endLockup, ease: E.cam },
  { f: CUE.musicEnd + 40, v: P.endHold, ease: E.linear },
];

const TRACKS: Record<Format, Key<Cam>[]> = {
  landscape: cameraKeys(landscapePoses()),
  portrait: cameraKeys(portraitPoses()),
};

export const cameraAt = (f: number, format: Format = 'landscape'): Cam => trackObj(TRACKS[format], f);

/** Day (0) / night (1): the room darkens for the decision and the trust scene. */
const NIGHT: Key<number>[] = [
  { f: 0, v: 0 },
  { f: CUE.dusk, v: 0 },
  { f: CUE.ratchet3, v: 1, ease: E.inOut },
  { f: CUE.dawn, v: 1 },
  { f: CUE.toChat + 30, v: 0, ease: E.inOut },
];
export const nightAt = (f: number) => track(NIGHT, f);

/** The device jumps from A to B while the camera is on the trackers (never on screen). */
export const DEVICE_SWAP = bar(18) + 36; // 1329
export const deviceAt = (f: number, format: Format = 'landscape') =>
  f < DEVICE_SWAP ? STAGES[format].devA : STAGES[format].devB;

/**
 * How far the picture moves this frame (max over the frame's corners and centre,
 * in output pixels), from the camera alone.
 */
export const cameraTravel = (f: number, W: number, H: number, format: Format = 'landscape') => {
  const a = cameraAt(f - 0.5, format);
  const b = cameraAt(f + 0.5, format);
  const sa = H / a.span;
  const sb = H / b.span;
  let max = 0;
  for (const [x, y] of [[0, 0], [W, 0], [0, H], [W, H], [W / 2, H / 2]]) {
    const px = (x - W * (0.5 + a.ox)) / sa + a.cx;
    const py = (y - H * (0.5 + a.oy)) / sa + a.cy;
    const x2 = (px - b.cx) * sb + W * (0.5 + b.ox);
    const y2 = (py - b.cy) * sb + H * (0.5 + b.oy);
    max = Math.max(max, Math.hypot(x2 - x, y2 - y));
  }
  return max;
};

/** Moments where things inside the phone move fast even though the camera may not. */
const FAST_UI: Array<[number, number]> = [
  [CUE.open, CUE.opened + 4], // the mark unfolding into the phone
  [CUE.composerIn, CUE.composerIn + 20], // the composer rising
  [CUE.toMyPosts, CUE.toMyPosts + 24], // container transform
  [CUE.toDetail, CUE.toDetail + 26], // container transform
  [CUE.toSecure, CUE.toSecure + 22], // shared axis + the amount in flight
  [CUE.toChat, CUE.toChat + 24], // shared axis + the title in flight
  [CUE.barsIn + 14, CUE.markComplete], // the bars closing in
];

/** Fastest measured motion INSIDE the phone this frame, in capture px per frame. */
const uiSpeed = (f: number) => {
  const d = (g: (x: number) => number) => Math.abs(g(f + 0.5) - g(f - 0.5));
  return Math.max(
    d(discoverScroll), // the feed flicks
    d(detailScroll), // the request scrolling to its protection card
    d((x) => composerRise(x) * 2400), // the composer rising
    d(stackOffset), // the conversation moving up as replies arrive
  );
};

/**
 * Motion-blur samples for frame f: 1 (off) unless the picture is really moving.
 * Speed is the faster of the camera and the UI inside the phone, so a fast
 * flick under a still camera is blurred too. Enough samples that neighbouring
 * copies sit <= ~3 px apart (180-degree shutter): a smear, never echoes.
 */
export const blurSamplesAt = (f: number, W: number, H: number, format: Format = 'landscape') => {
  const s = H / cameraAt(f, format).span;
  const v = Math.max(cameraTravel(f, W, H, format), uiSpeed(f) * s);
  const ui = FAST_UI.some(([a, b]) => f >= a && f <= b);
  if (v < 6 && !ui) return 1;
  const needed = Math.ceil((v * 0.5) / 3);
  return Math.min(24, Math.max(ui ? 12 : 3, needed));
};

/** How strongly the portrait copy band is showing (0..1), from the caption windows. */
export const captionBandAt = (f: number) => {
  const windows: Array<[number, number]> = [
    [CUE.capDiscover, CUE.fabDown - 6],
    [CUE.capAsk, CUE.toMyPosts + 18],
    [CUE.capSecure, CUE.capSecureOut],
    [CUE.capChat, CUE.m4 + 26],
    [CUE.capProgress, CUE.capProgressOut],
    [CUE.capRecord, CUE.capRecordOut],
  ];
  let v = 0;
  for (const [a, b] of windows) {
    const inn = Math.min(1, Math.max(0, (f - (a - 12)) / 14));
    const out = 1 - Math.min(1, Math.max(0, (f - b) / 14));
    v = Math.max(v, Math.min(inn, out));
  }
  return v;
};
