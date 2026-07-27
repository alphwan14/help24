import { FeedSignal } from '../types';
import { clamp, daysBetween, interpolate } from '../curves';

/**
 * Penalty — the listing has almost certainly been resolved offline.
 *
 * A five-month-old open request in a same-day services marketplace is not an
 * opportunity. That tap got fixed in February. The person is not waiting.
 *
 * Nothing in the first generation of this engine knew that. Freshness handles
 * *ordering* among live posts — it decays smoothly toward zero and can only
 * ever decline to award its 10 points — but it has no way to say "this one is
 * dead". So in a thin feed, where most signals sit at their neutral values, a
 * long-abandoned post could drift to the top on nothing but the absence of
 * competition. That is what happened in production.
 *
 * WHY A PENALTY AND NOT A RETRIEVAL CUT-OFF
 * -----------------------------------------
 * A hard `created_at > now() - 90 days` in `fn_feed_candidates` would be
 * cheaper and is the wrong instrument: it makes old posts *unreachable*,
 * including the genuinely long-lived ones (a standing offer, a recruiter's
 * evergreen job post) and including cases where the corpus is so small that a
 * stale post is better than an empty feed. A penalty demotes without deleting,
 * which is the same choice made for own-posts and already-applied.
 *
 * WHAT THIS IS NOT A SUBSTITUTE FOR
 * ---------------------------------
 * Posts should expire in the DATA — an `open` row that nobody has touched for
 * three months is a lie the whole product tells, not just the feed (it inflates
 * counts, notifications and any future analytics). This penalty stops the feed
 * repeating that lie; it does not make the row true. See the testing doc's
 * known-issues section.
 */
export const stalenessSignal: FeedSignal = {
  key: 'staleness',
  label: 'Likely resolved',

  weight: (config) => config.weights.staleness,

  score: (candidate, viewer, config) => {
    const ageDays = daysBetween(viewer.now, candidate.createdAt);
    // Ramps 0 → 1 between staleAfterDays and deadAfterDays, so the demotion
    // arrives gradually. A cliff would make a post visibly fall off the feed
    // overnight, which reads as a bug from the outside.
    return clamp(
      interpolate(ageDays, [
        [config.staleness.staleAfterDays, 0],
        [config.staleness.deadAfterDays, 1],
      ]),
    );
  },

  detail: (candidate, viewer) => ({
    ageDays: Math.round(daysBetween(viewer.now, candidate.createdAt)),
  }),
};
