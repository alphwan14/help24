/**
 * The decay curves every signal is built from. Pure maths, no domain knowledge.
 *
 * They live in one file because "smooth" is a stated product requirement, not a
 * detail: a feed with cliff-edge scoring visibly jumps when a post crosses an
 * invisible threshold, and users read that as randomness.
 */

/** Clamp to [lo, hi]. NaN maps to `lo` — no signal may ever emit NaN. */
export function clamp(value: number, lo = 0, hi = 1): number {
  if (!Number.isFinite(value)) return lo;
  return value < lo ? lo : value > hi ? hi : value;
}

/**
 * Rational decay: `1 / (1 + (x / halfPoint) ^ steepness)`.
 *
 * Scores exactly 0.5 at `x = halfPoint`, approaches 0 asymptotically, and never
 * reaches it — so "far away" always ranks below "near" but is never eliminated.
 * With halfPoint=15 km, steepness=1.5 this is the distance curve the brief asks
 * for: 1 km→0.98, 5→0.84, 20→0.39, 100→0.06.
 */
export function rationalDecay(x: number, halfPoint: number, steepness: number): number {
  if (!Number.isFinite(x) || x <= 0) return 1;
  const hp = halfPoint > 0 ? halfPoint : 1;
  const p = steepness > 0 ? steepness : 1;
  return clamp(1 / (1 + Math.pow(x / hp, p)));
}

/**
 * Exponential half-life decay: `0.5 ^ (x / halfLife)`.
 * At x = halfLife the score is exactly 0.5. Used for freshness and for
 * time-decayed weights.
 */
export function halfLifeDecay(x: number, halfLife: number): number {
  if (!Number.isFinite(x) || x <= 0) return 1;
  const hl = halfLife > 0 ? halfLife : 1;
  return clamp(Math.pow(0.5, x / hl));
}

/**
 * Piecewise-linear interpolation over `[x, y]` anchors.
 *
 * Preferred over bucketed if/else wherever the product spec gives named tiers
 * ("0–2 h huge, 2–6 h high, 6–24 h medium"): it honours the intended shape
 * while staying continuous, so a post does not visibly lurch down the feed the
 * instant it turns two hours old.
 *
 * Anchors need not be pre-sorted. Before the first anchor the first y is held;
 * after the last anchor the last y is held.
 */
export function interpolate(x: number, anchors: [number, number][]): number {
  if (!anchors || anchors.length === 0) return 0;
  const pts = [...anchors]
    .filter((a) => Array.isArray(a) && Number.isFinite(a[0]) && Number.isFinite(a[1]))
    .sort((a, b) => a[0] - b[0]);
  if (pts.length === 0) return 0;

  if (!Number.isFinite(x) || x <= pts[0][0]) return pts[0][1];
  if (x >= pts[pts.length - 1][0]) return pts[pts.length - 1][1];

  for (let i = 0; i < pts.length - 1; i++) {
    const [x0, y0] = pts[i];
    const [x1, y1] = pts[i + 1];
    if (x >= x0 && x <= x1) {
      if (x1 === x0) return y1;
      return y0 + ((y1 - y0) * (x - x0)) / (x1 - x0);
    }
  }
  return pts[pts.length - 1][1];
}

/**
 * Saturating count curve: `x / (x + k)`.
 *
 * 0 → 0, k → 0.5, and it flattens after that. This is how a count becomes a
 * ranking input without letting one runaway number dominate: the difference
 * between 2 and 4 applications matters, the difference between 40 and 80 does
 * not.
 */
export function saturate(x: number, k: number): number {
  if (!Number.isFinite(x) || x <= 0) return 0;
  const kk = k > 0 ? k : 1;
  return clamp(x / (x + kk));
}

/** Hours between two instants; negative differences clamp to 0. */
export function hoursBetween(later: Date, earlier: Date): number {
  const ms = later.getTime() - earlier.getTime();
  if (!Number.isFinite(ms) || ms <= 0) return 0;
  return ms / 3_600_000;
}

/** Days between two instants; negative differences clamp to 0. */
export function daysBetween(later: Date, earlier: Date): number {
  return hoursBetween(later, earlier) / 24;
}
