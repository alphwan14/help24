/**
 * Where everything is, in the real captures.
 *
 * All captures are 1080 x 2400 (Galaxy S20+, ADB screencap, 25 Sep 2026) and
 * live in public/screens/, produced by ../../captures/process_captures.py
 * (which only cleans OS chrome). Every rect here was measured off those files
 * with ../../captures/measure.py - if a capture is replaced, re-measure here.
 *
 * Rect = { x, y, w, h } in capture pixels.
 */
export type Rect = { x: number; y: number; w: number; h: number };
export const r = (x: number, y: number, w: number, h: number): Rect => ({ x, y, w, h });

export const SCREEN_W = 1080;
export const SCREEN_H = 2400;
export const STATUS_H = 84;

/** page background of the app (tokens.dart `page`) */
export const APP_PAGE = '#FAF9F7';

export const SHOT = {
  discover: 'discover',
  discoverTop: 'discover-top',
  discoverScroll1: 'discover-scroll1',
  discoverScroll2: 'discover-scroll2',
  composer: 'post-composer',
  myposts: 'myposts',
  detailTop: 'detail-top',
  detailScrolled: 'detail-scrolled',
  secure: 'secure',
  chat: 'chat',
  jobStatus: 'job-status',
  historyWork: 'history-work',
} as const;

/* ------------------------------------------------------------------ Discover */
export const DISCOVER = {
  /** status + "Discover" + search + filter chips; the list starts under it */
  top: r(0, 0, 1080, 568),
  allChip: r(45, 422, 139, 112),
  /** list viewport: the app clips the list at row 568, and the nav hairline starts at 2141 */
  viewport: r(0, 568, 1080, 1573),
  nav: r(0, 2141, 1080, 259),
  /** flat (no shadow): verified by diffing two scroll positions */
  fab: r(763, 1939, 273, 158),
  fabRadius: 48,
  /**
   * The feed is stitched from four captures of the same list at different
   * scroll positions. "content y" is y in the `discover` capture at scroll 0.
   * Seams sit in the empty gaps between cards, and no piece contains the
   * floating +Post button (it is drawn once, on top, as it is in the app).
   */
  feed: [
    { shot: 'discover-top', srcY: 1140, contentY: 524, h: 54 }, // Kitchen card's top edge (offset 616)
    { shot: 'discover', srcY: 578, contentY: 578, h: 1033 },
    { shot: 'discover-scroll1', srcY: 1352, contentY: 1611, h: 573 }, // offset 259
    { shot: 'discover-scroll2', srcY: 1052, contentY: 2184, h: 887 }, // offset 1132
  ],
  feedTop: 524,
  feedBottom: 3071,
  /** scroll offsets: -42 frames the Kitchen card cleanly; 928 is the stitched limit */
  scrollMin: -42,
  scrollMax: 928,
  cards: {
    kitchen: r(46, 548, 988, 473),
    welder: r(46, 1054, 988, 541),
    tutoring: r(46, 1628, 988, 540),
    plumbing: r(46, 2201, 988, 547),
  },
};

/* ------------------------------------------------------------------ Composer */
export const COMPOSER = {
  head: r(0, 0, 1080, 372), // status, "What would you like to do?", close, step bar
  request: r(56, 382, 968, 321),
  offer: r(56, 736, 968, 322),
  job: r(56, 1091, 968, 321),
  cont: r(56, 1502, 968, 146),
  cardRadius: 40,
};

/* ------------------------------------------------------------------ My posts */
export const MYPOSTS = {
  dogCard: r(45, 973, 990, 581),
  dogTitle: r(88, 1083, 520, 43),
  cardRadius: 40,
};

/* ------------------------------------------------------------------ Post detail */
export const DETAIL = {
  appBar: r(0, 0, 1080, 229), // white status band + back / delete
  /** stitched content: detail-top above the seam, detail-scrolled (offset 500) below */
  content: [
    { shot: 'detail-top', srcY: 229, contentY: 229, h: 1767 },
    { shot: 'detail-scrolled', srcY: 1496, contentY: 1996, h: 647 },
  ],
  viewport: r(0, 229, 1080, 1914),
  scrollMax: 500,
  title: r(60, 414, 569, 49),
  /** in content coordinates (subtract scroll to get screen y) */
  protectionCard: r(56, 2030, 968, 355),
  bottomBar: r(0, 2143, 1080, 257),
  button: r(45, 2178, 990, 146),
  buttonRadius: 34,
  /** "KES 2,545" inside the button label */
  buttonAmount: r(640, 2222, 220, 60),
};

/* ------------------------------------------------------------------ Secure this service */
export const SECURE = {
  appBar: r(0, 0, 1080, 240),
  header: r(44, 250, 992, 220),
  headerTitle: r(259, 317, 457, 38),
  breakdown: r(44, 503, 992, 417),
  total: r(687, 806, 286, 56),
  mpesa: r(44, 953, 992, 240),
  protection: r(44, 1214, 992, 186),
  pay: r(44, 1474, 992, 152),
  caption: r(0, 1652, 1080, 52),
  rest: r(0, 1704, 1080, 696),
  /** exact card edges, for the focus window and the lifted note (no page margin = no halo) */
  breakdownCard: r(56, 506, 968, 411),
  protectionCard: r(56, 1217, 968, 181),
  cardRadius: 32,
};

/* ------------------------------------------------------------------ Chat */
export const CHAT = {
  top: r(0, 0, 1080, 222), // status band + app bar (name, last seen)
  banner: r(0, 222, 1080, 160), // pinned job banner incl. its bottom hairline
  bannerTitle: r(149, 267, 425, 35),
  viewport: r(0, 382, 1080, 1763),
  composer: r(0, 2145, 1080, 255),
  dateChip: r(0, 448, 1080, 76),
  /** bubbles at their capture positions; `out` = sent by the customer */
  msgs: [
    { id: 'm1', rect: r(257, 558, 778, 226), out: true },
    { id: 'm2', rect: r(124, 800, 777, 287), out: false },
    { id: 'm3', rect: r(258, 1103, 777, 167), out: true },
    { id: 'm4', rect: r(124, 1286, 714, 169), out: false },
    { id: 'm5', rect: r(124, 1461, 443, 281), out: false }, // "Arrived 12:11 PM"
    { id: 'm6', rect: r(124, 1748, 695, 172), out: false }, // "I've arrived at the location."
  ],
  arrivedInner: r(164, 1490, 362, 172),
  /** the author's avatar sits beside the LAST bubble of an incoming run */
  avatar: r(33, 1840, 80, 80),
  /** latest bubble rests with its bottom here (just above the composer) */
  restBottom: 2112,
};

/* ------------------------------------------------------------------ Job status (trackers) */
export const JOB = {
  /** exact card edges (border included), so a lifted card carries no page margin */
  payment: r(45, 801, 990, 572),
  /** step-row boundaries (capture y): Required, Sent, Protected, Payout Pending, Payout Released */
  paymentRows: [940, 1019, 1098, 1177, 1256, 1336],
  completion: r(45, 1406, 990, 493),
  cardRadius: 42,
  borderW: 5,
  /** In Progress, Completion Requested, Awaiting Approval, Approved */
  completionRows: [1545, 1624, 1703, 1782, 1864],
};

/* ------------------------------------------------------------------ Service history */
export const HISTORY = {
  top: r(0, 0, 1080, 380),
  summary: r(44, 397, 992, 230),
  rows: [r(44, 661, 992, 393), r(44, 1077, 992, 393), r(44, 1494, 992, 393), r(44, 1910, 992, 393)],
  bottom: r(0, 2303, 1080, 97),
  /** "Payment protected" on the Cake Maker row - becomes the crossbar */
  protectedChip: r(87, 2179, 360, 68),
};
