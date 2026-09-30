import { Easing } from 'remotion';

/**
 * Motion vocabulary. Kept deliberately small so the whole film moves with one
 * hand. Curves are the ones premium UI motion actually uses (Material 3 +
 * common product-film practice): ease-out entrances, a standard curve for
 * on-screen moves, a symmetric curve for the camera, a quick accelerate for exits.
 */
export const E = {
  /** entrances: fast start, long settle */
  out: Easing.bezier(0.23, 1, 0.32, 1),
  /** Material "emphasized decelerate" - sheets, screens arriving */
  enter: Easing.bezier(0.05, 0.7, 0.1, 1),
  /** exits: gather speed and leave */
  exit: Easing.bezier(0.3, 0, 0.8, 0.15),
  /** things moving while on screen (Material standard) */
  move: Easing.bezier(0.2, 0, 0, 1),
  /** the camera: symmetric, no overshoot */
  cam: Easing.bezier(0.65, 0, 0.35, 1),
  /** a firmer in-out for long travels */
  inOut: Easing.bezier(0.77, 0, 0.175, 1),
  /** a short ease-out push, used for the ratchet steps */
  push: Easing.bezier(0.16, 1, 0.3, 1),
  linear: (t: number) => t,
};

export const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
export const mix = (a: number, b: number, t: number) => a + (b - a) * t;

/** 0 -> 1 between frames f0 and f1, eased. */
export const ramp = (f: number, f0: number, f1: number, ease: (t: number) => number = E.move) => {
  if (f1 <= f0) return f >= f1 ? 1 : 0;
  return ease(clamp01((f - f0) / (f1 - f0)));
};

/** Rises over [a0,a1], holds, falls over [b0,b1]. */
export const win = (
  f: number,
  a0: number,
  a1: number,
  b0: number,
  b1: number,
  inEase: (t: number) => number = E.out,
  outEase: (t: number) => number = E.exit,
) => Math.min(ramp(f, a0, a1, inEase), 1 - ramp(f, b0, b1, outEase));

export type Key<T> = { f: number; v: T; ease?: (t: number) => number };

/**
 * Keyframed value. `ease` on a key shapes the segment that ENDS at that key,
 * so a track reads like a shot list: "by frame f, be at v, getting there like this".
 */
export function track(keys: Key<number>[], f: number): number {
  if (f <= keys[0].f) return keys[0].v;
  for (let i = 1; i < keys.length; i++) {
    const k = keys[i];
    if (f <= k.f) {
      const p = keys[i - 1];
      const t = (k.ease ?? E.cam)(clamp01((f - p.f) / Math.max(1, k.f - p.f)));
      return mix(p.v, k.v, t);
    }
  }
  return keys[keys.length - 1].v;
}

export function trackObj<T extends Record<string, number>>(keys: Key<T>[], f: number): T {
  if (f <= keys[0].f) return { ...keys[0].v };
  for (let i = 1; i < keys.length; i++) {
    const k = keys[i];
    if (f <= k.f) {
      const p = keys[i - 1];
      const t = (k.ease ?? E.cam)(clamp01((f - p.f) / Math.max(1, k.f - p.f)));
      const out = {} as Record<string, number>;
      for (const key of Object.keys(k.v)) out[key] = mix(p.v[key] ?? k.v[key], k.v[key], t);
      return out as T;
    }
  }
  return { ...keys[keys.length - 1].v };
}

/**
 * A small damped spring, evaluated in closed form so it is deterministic per frame.
 * `bounce` 0 = critically damped, 0.15 = the "barely there" settle used for bubbles.
 * Returns progress 0 -> 1 (may slightly exceed 1 when bounce > 0).
 */
export function springAt(f: number, f0: number, durationFrames: number, bounce = 0) {
  if (f <= f0) return 0;
  const t = (f - f0) / durationFrames; // 1.0 ~ settled
  if (bounce <= 0) {
    // critically damped approximation
    const w = 7.5;
    return 1 - (1 + w * t) * Math.exp(-w * t);
  }
  const zeta = 1 - bounce;
  const w0 = 7.5;
  const wd = w0 * Math.sqrt(1 - zeta * zeta);
  return 1 - Math.exp(-zeta * w0 * t) * (Math.cos(wd * t) + ((zeta * w0) / wd) * Math.sin(wd * t));
}

/** Deterministic pseudo-random in [0,1) from an integer seed. */
export const rand = (seed: number) => {
  const x = Math.sin(seed * 127.1 + 311.7) * 43758.5453;
  return x - Math.floor(x);
};
