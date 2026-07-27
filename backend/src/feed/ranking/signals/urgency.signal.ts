import { FeedSignal } from '../types';
import { halfLifeDecay, hoursBetween, interpolate, clamp } from '../curves';

/**
 * Signal 4 — Urgency. A strong boost that expires.
 *
 * Two separate notions of urgency exist in the data and both are honoured:
 *
 *   * `is_urgent` + `urgent_expires_at` — a real emergency with a hard window
 *     ("Right now" posts). While the window is open the post is scored on the
 *     spec's decay: 0–2 h huge, 2–6 h high, 6–24 h medium.
 *   * the `urgency` enum (`urgent` / `soon` / `flexible`) — the poster's stated
 *     priority, no window, a much smaller boost.
 *
 * **After expiry the emergency boost is gone entirely** and the post falls back
 * to its enum score — the spec's "after expiry → normal ranking". A stale
 * emergency that keeps its boost is worse than no urgency feature at all,
 * because it teaches users the flag is noise.
 *
 * **The enum score decays too.** This was documented from the start and not
 * implemented, and the gap was visible in production: a request marked urgent
 * five months ago still collected 9 of the 18 points, forever, because the
 * fallback returned a flat 0.5. Nobody's emergency is still an emergency in
 * February. `enumHalfLifeHours` (72 h) means a post marked urgent today keeps
 * its modest edge and one from last season keeps nothing.
 *
 * Decay is measured from `created_at` (a reliable TIMESTAMPTZ) rather than from
 * `urgent_expires_at` (a naked TIMESTAMP the app writes from local time — see
 * migration 095). `urgent_expires_at` is used only as the on/off cutoff, where
 * a few hours of timezone skew cannot invert an ordering.
 *
 * This also fixes the audit's §3.4: urgency was a membership filter feeding a
 * separate 5-item banner, and contributed nothing to the main feed's order.
 */
export const urgencySignal: FeedSignal = {
  key: 'urgency',
  label: 'Urgency',

  weight: (config) => config.weights.urgency,

  score: (candidate, viewer, config) => {
    const hoursOld = hoursBetween(viewer.now, candidate.createdAt);

    // A stated priority is a claim about a moment, so it ages like one.
    const enumScore =
      clamp(config.urgency.enumScores[candidate.urgency] ?? 0) *
      halfLifeDecay(hoursOld, config.urgency.enumHalfLifeHours);

    const windowOpen =
      candidate.isUrgent &&
      candidate.urgentExpiresAt != null &&
      candidate.urgentExpiresAt.getTime() > viewer.now.getTime();

    if (!windowOpen) return clamp(enumScore);

    const emergency = clamp(interpolate(hoursOld, config.urgency.anchors));

    // Never let a decayed emergency score BELOW what the same post would get
    // from its enum alone — decay reduces the bonus, it does not invert it.
    return clamp(Math.max(emergency, enumScore));
  },

  detail: (candidate, viewer) => ({
    isUrgent: candidate.isUrgent,
    windowOpen:
      candidate.isUrgent &&
      candidate.urgentExpiresAt != null &&
      candidate.urgentExpiresAt.getTime() > viewer.now.getTime(),
    hoursOld: Math.round(hoursBetween(viewer.now, candidate.createdAt) * 10) / 10,
    urgencyEnum: candidate.urgency,
  }),
};
