import { RankingCandidate, ViewerProfession } from '../types';
import { haystackOf } from '../text-index';

/**
 * The matcher shared by signals 2 (profession) and 3 (skills).
 *
 * Three tiers of evidence, deliberately far apart so the explanation is
 * readable at a glance:
 *
 *   1.00  the post's category IS one this profession maps to
 *         (`professions.category_id` → `categories.name`) — the strong claim
 *   0.55  the post's category belongs to a profession in the same GROUP
 *         (`professions.group_id`) — adjacent trade, real but weaker
 *   0.35  a profession token (its name or one of its 089 aliases, including
 *         the Kiswahili ones — "fundi", "mama fua", "boda") appears in the
 *         post's title or description — text evidence only
 *   0.00  nothing matched
 *
 * Tier 3 exists because `posts.category` is a 34-value list while the
 * profession catalogue has 482 entries: a "Generator Repair" request is filed
 * under Electrical, and only the text says which specialist it actually wants.
 */

export const PROFESSION_MATCH_EXACT = 1.0;
export const PROFESSION_MATCH_GROUP = 0.55;
export const PROFESSION_MATCH_TOKEN = 0.35;
export const PROFESSION_MATCH_NONE = 0;

export interface ProfessionMatch {
  score: number;
  professionId: string | null;
  tier: 'category' | 'group' | 'token' | 'none';
}

const NO_MATCH: ProfessionMatch = {
  score: PROFESSION_MATCH_NONE,
  professionId: null,
  tier: 'none',
};

/** Case/whitespace-insensitive comparison for registry values. */
function sameName(a: string | null | undefined, b: string | null | undefined): boolean {
  if (!a || !b) return false;
  return a.trim().toLowerCase() === b.trim().toLowerCase();
}

/**
 * Best match between a candidate post and one profession the viewer can serve.
 *
 * `groupCategoryNames` maps `groupId` → every category name reachable from that
 * group, so tier 2 can be evaluated without a per-candidate database lookup.
 */
export function matchProfession(
  candidate: RankingCandidate,
  profession: ViewerProfession,
  groupCategoryNames: Map<string, Set<string>>,
): ProfessionMatch {
  const postCategory = candidate.category;
  if (!postCategory) return NO_MATCH;

  // Tier 1 — exact category.
  if (profession.categoryNames.some((name) => sameName(name, postCategory))) {
    return { score: PROFESSION_MATCH_EXACT, professionId: profession.id, tier: 'category' };
  }

  // Tier 2 — adjacent trade in the same profession group.
  if (profession.groupId) {
    const groupCategories = groupCategoryNames.get(profession.groupId);
    if (groupCategories && groupCategories.has(postCategory.trim().toLowerCase())) {
      return { score: PROFESSION_MATCH_GROUP, professionId: profession.id, tier: 'group' };
    }
  }

  // Tier 3 — the profession's own vocabulary appears in the post text.
  // Evaluated last, and only when the cheap category checks failed, so the
  // string scan is the exception rather than the rule.
  if (profession.tokens.length > 0) {
    const haystack = haystackOf(candidate);
    if (profession.tokens.some((token) => token.length >= 3 && haystack.includes(token))) {
      return { score: PROFESSION_MATCH_TOKEN, professionId: profession.id, tier: 'token' };
    }
  }

  return NO_MATCH;
}

/**
 * Best match across a set of professions, each scaled by its own weight
 * (1.0 for the primary trade, `user_skills.weight` for a secondary one) so a
 * weakly-held side skill can never outrank the trade someone actually does.
 */
export function bestProfessionMatch(
  candidate: RankingCandidate,
  professions: ViewerProfession[],
  groupCategoryNames: Map<string, Set<string>>,
): ProfessionMatch {
  let best = NO_MATCH;
  for (const profession of professions) {
    const match = matchProfession(candidate, profession, groupCategoryNames);
    const weighted = match.score * profession.weight;
    if (weighted > best.score) {
      best = { ...match, score: weighted };
    }
  }
  return best;
}
