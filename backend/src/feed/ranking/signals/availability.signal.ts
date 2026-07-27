import { FeedSignal } from '../types';
import { hoursBetween } from '../curves';

/**
 * Signal 7 — Provider availability.
 *
 * "If a provider marked themselves Available now, boost them. If unavailable,
 * reduce ranking."
 *
 * Applies to `offer` posts ONLY. On a request or a job the author is the buyer,
 * and whether the buyer is at their phone says nothing about whether the
 * opportunity is worth answering — so the signal returns `null` and its weight
 * leaves the calculation rather than scoring every request identically.
 *
 * `users.available_until` is a WINDOW, not a boolean (migration 093). A
 * provider who tapped "available now" on Tuesday and forgot is not available on
 * Friday, and a boolean would have the ranking engine amplify that lie every
 * day until they remembered. A window expires on its own.
 *
 * When no window is set — which is every user until the profile UI ships this —
 * the signal falls back to `last_seen`, so "reduce ranking" applies to
 * genuinely dormant providers rather than to everyone who has not discovered
 * the toggle.
 */
export const availabilitySignal: FeedSignal = {
  key: 'availability',
  label: 'Availability',

  weight: (config) => config.weights.availability,

  score: (candidate, viewer, config) => {
    if (candidate.type !== 'offer') return null;

    const cfg = config.availability;

    if (
      candidate.authorAvailableUntil != null &&
      candidate.authorAvailableUntil.getTime() > viewer.now.getTime()
    ) {
      return cfg.availableNowScore;
    }

    if (candidate.authorLastSeen == null) return cfg.staleScore;

    const hoursSinceSeen = hoursBetween(viewer.now, candidate.authorLastSeen);
    if (hoursSinceSeen <= 24) return cfg.activeWithin24hScore;
    if (hoursSinceSeen <= 24 * 7) return cfg.activeWithin7dScore;
    return cfg.staleScore;
  },

  detail: (candidate, viewer) => {
    if (candidate.type !== 'offer') return undefined;
    return {
      availableNow:
        candidate.authorAvailableUntil != null &&
        candidate.authorAvailableUntil.getTime() > viewer.now.getTime(),
      hoursSinceLastSeen:
        candidate.authorLastSeen == null
          ? null
          : Math.round(hoursBetween(viewer.now, candidate.authorLastSeen)),
    };
  },
};
