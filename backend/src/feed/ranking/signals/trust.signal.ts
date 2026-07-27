import { FeedSignal } from '../types';
import { clamp } from '../curves';

/**
 * Signal 14 — Trust badges. "Verified providers, businesses, top-rated
 * professionals receive ranking bonuses."
 *
 * Kept separate from signal 8 (reliability) on purpose, because the two answer
 * different questions and can disagree:
 *
 *   * `reliability` = **has this provider delivered?** — derived from reviews,
 *     completions and disputes. Earned by working.
 *   * `trust` = **is this provider who they say they are?** — verification,
 *     business registration, and the tier those two combine into. Conferred by
 *     Help24.
 *
 * A verified newcomer with no jobs scores high here and neutral there; a
 * long-serving unverified individual scores the reverse. Folding them into one
 * number would make both unexplainable.
 *
 * Every user is `is_verified = false`, `account_type = 'individual'`,
 * `tier = 'new_provider'` until something changes that, and all three score
 * 0 — i.e. **no bonus**, not a penalty. Applying migration 093 therefore moves
 * nobody's position; trust only starts differentiating once verification
 * actually begins.
 */
export const trustSignal: FeedSignal = {
  key: 'trust',
  label: 'Trust',

  weight: (config) => config.weights.trust,

  score: (candidate, _viewer, config) => {
    const cfg = config.trust;
    const verified = candidate.authorIsVerified ? 1 : 0;
    const business = candidate.authorAccountType === 'business' ? 1 : 0;
    const tier = clamp(cfg.tierScores[candidate.tier ?? 'new_provider'] ?? 0);

    return clamp(cfg.verifiedWeight * verified + cfg.businessWeight * business + cfg.tierWeight * tier);
  },

  detail: (candidate) => ({
    verified: candidate.authorIsVerified,
    accountType: candidate.authorAccountType,
    tier: candidate.tier ?? 'new_provider',
  }),
};
