import { FeedSignal } from '../types';
import { bestProfessionMatch } from './profession-match';

/**
 * Signal 3 — Secondary skills.
 *
 * "Later users may have multiple skills — Electrician, Solar, Generator
 * Repair, Industrial Wiring. Each increases relevance. Design today's
 * architecture for that future."
 *
 * The architecture is here and live, not stubbed: `user_skills` (migration 093)
 * exists, `ViewerContextService` reads it, and this signal scores it with the
 * same three-tier matcher the primary profession uses. It simply ships with an
 * empty table, so today it returns `null` for every user and contributes
 * nothing — the day a user adds "solar", solar work starts surfacing with no
 * further work.
 *
 * Two things keep it subordinate to signal 2, which is the point:
 *   * a lower weight (10 vs 25), and
 *   * each skill's own `user_skills.weight` (0..1) multiplying its match, so a
 *     hedged side skill scores well below a confident primary trade.
 */
export const skillsSignal: FeedSignal = {
  key: 'skills',
  label: 'Skills match',

  weight: (config) => config.weights.skills,

  score: (candidate, viewer) => {
    const secondary = viewer.professions.filter((p) => !p.isPrimary);
    if (secondary.length === 0) return null;
    return bestProfessionMatch(candidate, secondary, viewer.groupCategoryNames).score;
  },

  detail: (candidate, viewer) => {
    const secondary = viewer.professions.filter((p) => !p.isPrimary);
    if (secondary.length === 0) return undefined;
    const match = bestProfessionMatch(candidate, secondary, viewer.groupCategoryNames);
    return {
      matchedSkill: match.professionId,
      tier: match.tier,
      skillCount: secondary.length,
    };
  },
};
