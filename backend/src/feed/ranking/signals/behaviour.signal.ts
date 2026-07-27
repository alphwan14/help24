import { FeedSignal } from '../types';
import { clamp } from '../curves';

/**
 * Signal 9 — User behaviour. Personalisation without machine learning.
 *
 * "Observe what categories users open, which posts they save, which
 * professions they message, which providers they contact, which jobs they
 * apply for. Increase similar content." — with the explicit constraint
 * *"without using ML"*.
 *
 * So this is arithmetic, and every step of it is inspectable:
 *
 *   1. `user_interactions` (migration 091) records one row per action;
 *   2. `fn_user_affinity` sums `event_weight × exp(−age_days / 14)` per
 *      category / profession / author and normalises each dimension to 0..1;
 *   3. this signal takes the strongest of the three that applies.
 *
 * Author affinity is discounted by `authorFactor` (0.8) because it is the
 * narrowest evidence — liking one provider says less about what you want next
 * than liking a whole category does. It is also the seam where "repeat
 * customers" and "favourite providers" arrive for free later: a `hire` event
 * already carries the heaviest weight in the table.
 *
 * Returns `null` for a signed-out viewer or one with no history, so a brand-new
 * user's feed is ranked on distance, profession and urgency rather than being
 * uniformly flattened by a signal that has nothing to say about them.
 */
export const behaviourSignal: FeedSignal = {
  key: 'behaviour',
  label: 'Your activity',

  weight: (config) => config.weights.behaviour,

  score: (candidate, viewer, config) => {
    const hasHistory =
      viewer.categoryAffinity.size > 0 ||
      viewer.professionAffinity.size > 0 ||
      viewer.authorAffinity.size > 0;
    if (!hasHistory) return null;

    const byCategory = viewer.categoryAffinity.get(candidate.category) ?? 0;

    const byProfession = candidate.authorProfession
      ? viewer.professionAffinity.get(candidate.authorProfession) ?? 0
      : 0;

    const byAuthor =
      (viewer.authorAffinity.get(candidate.authorUserId) ?? 0) * config.behaviour.authorFactor;

    return clamp(Math.max(byCategory, byProfession, byAuthor));
  },

  detail: (candidate, viewer, config) => ({
    categoryAffinity: viewer.categoryAffinity.get(candidate.category) ?? 0,
    professionAffinity: candidate.authorProfession
      ? viewer.professionAffinity.get(candidate.authorProfession) ?? 0
      : 0,
    authorAffinity:
      (viewer.authorAffinity.get(candidate.authorUserId) ?? 0) * config.behaviour.authorFactor,
  }),
};
