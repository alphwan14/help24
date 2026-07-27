import { FeedSignal } from '../types';
import { bestProfessionMatch } from './profession-match';

/**
 * Signal 2 — Profession match. The second-heaviest weight, by design.
 *
 * "If the user's profile profession is Electrician, the feed should heavily
 * prioritise electrical requests, electrical jobs, electrical offers." The
 * intended feeling is *"there are always electrical jobs available"*.
 *
 * This reads the viewer's PRIMARY trade only (`users.profession`); secondary
 * trades are signal 3, weighted lower, so an electrician who also lists
 * "solar" still sees electrical work first.
 *
 * The audit's finding this repays: migration 089 shipped a 482-profession
 * catalogue whose own header calls `category_id` "the seam for future
 * provider↔request matching", and nothing had ever read it. This is that seam.
 *
 * Returns `null` when the viewer has no profession set — a signal with no
 * input must not quietly score every post 0, because that would penalise the
 * whole feed of a user who simply has not filled in their profile.
 */
export const professionSignal: FeedSignal = {
  key: 'profession',
  label: 'Profession match',

  weight: (config) => config.weights.profession,

  score: (candidate, viewer) => {
    const primary = viewer.professions.filter((p) => p.isPrimary);
    if (primary.length === 0) return null;
    return bestProfessionMatch(candidate, primary, viewer.groupCategoryNames).score;
  },

  detail: (candidate, viewer) => {
    const primary = viewer.professions.filter((p) => p.isPrimary);
    if (primary.length === 0) return undefined;
    const match = bestProfessionMatch(candidate, primary, viewer.groupCategoryNames);
    return {
      matchedProfession: match.professionId,
      tier: match.tier,
      postCategory: candidate.category,
    };
  },
};
