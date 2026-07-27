import { FeedSignal } from '../types';
import { halfLifeDecay, hoursBetween } from '../curves';

/**
 * Signal 5 — Freshness.
 *
 * "New posts deserve discovery. Avoid old posts permanently dominating."
 *
 * Exponential half-life decay: exactly 0.5 at 24 h, 0.25 at 48 h, and
 * asymptotically approaching — but never reaching — zero. An old post is never
 * excluded, it just has to win on other signals, which is exactly what should
 * happen to a two-week-old request that is nonetheless 400 m away and in your
 * trade.
 *
 * Note the weight (10 of ~138 possible points). Recency was the ONLY ordering
 * signal before this engine existed; here it is one voice among twelve. That
 * demotion is the point of the whole exercise.
 */
export const freshnessSignal: FeedSignal = {
  key: 'freshness',
  label: 'Freshness',

  weight: (config) => config.weights.freshness,

  score: (candidate, viewer, config) =>
    halfLifeDecay(hoursBetween(viewer.now, candidate.createdAt), config.freshness.halfLifeHours),

  detail: (candidate, viewer) => ({
    hoursOld: Math.round(hoursBetween(viewer.now, candidate.createdAt) * 10) / 10,
  }),
};
