import { DiversityConfig, ScoredCandidate } from './types';

/**
 * Signals 12 and 13 — category diversity and anti-spam.
 *
 * These are not scores. A post cannot be "more diverse" in isolation; it is
 * only diverse *given what is already above it*. So they run after scoring, as
 * a selection pass over the sorted list.
 *
 * The problem being solved is concrete. Ordering by score alone means one
 * provider who posts ten offers in a minute owns the top ten rows of every
 * nearby user's feed — the audit found nothing anywhere in the pipeline that
 * would notice (§3.13). And ten plumbers in a row is a worse feed than five
 * plumbers and five other things, even when every plumber outscores every
 * alternative.
 *
 * ALGORITHM — greedy least-violation
 * ----------------------------------
 * For each slot, take the highest-scoring remaining candidate that breaks no
 * constraint. When every candidate breaks something — a page where one author
 * or one category is all there is — take the one whose violation set is
 * CHEAPEST, and break only that.
 *
 * Constraint costs are powers of two, cheapest first:
 *   1  consecutive category  — cosmetic
 *   2  consecutive type      — cosmetic
 *   4  consecutive author    — anti-spam, matters
 *   8  per-author page cap   — anti-spam, matters most
 *
 * Because the costs double, breaking BOTH cosmetic constraints (1+2=3) is still
 * cheaper than touching author capping (4). Variety is always given up before
 * spam protection is.
 *
 * Choosing per slot, rather than switching a constraint off globally, is
 * load-bearing. A fixed relaxation order gets this wrong in a way that is easy
 * to ship and hard to notice: when a page is all one post type,
 * `consecutiveType` blocks everything, a fixed order drops the cheapest
 * constraint (`consecutiveCategory`) — which was never the blocker — and a
 * third consecutive plumber appears that nothing had asked to allow.
 *
 * The page is never truncated. In the worst case every constraint gives way and
 * the output is exactly score order: a thin feed should be short on variety,
 * not short on posts.
 *
 * Deterministic: no randomness, no clock. The same input always produces the
 * same page, which pagination and the test suite both depend on.
 */

type ConstraintKey =
  | 'consecutiveCategory'
  | 'consecutiveType'
  | 'consecutiveAuthor'
  | 'authorPageCap';

/**
 * What breaking each constraint costs. Powers of two, so the total cost of a
 * violation SET is unambiguous: breaking the two cheapest constraints (1+2=3)
 * still costs less than breaking `consecutiveAuthor` alone (4). That ordering
 * is the anti-spam guarantee — cosmetic variety is always sacrificed before
 * author capping is.
 */
const CONSTRAINT_COST: Record<ConstraintKey, number> = {
  consecutiveCategory: 1,
  consecutiveType: 2,
  consecutiveAuthor: 4,
  authorPageCap: 8,
};

/** Most expensive first, for naming the reason a candidate was moved. */
const BY_SEVERITY: ConstraintKey[] = [
  'authorPageCap',
  'consecutiveAuthor',
  'consecutiveType',
  'consecutiveCategory',
];

/** Human-readable reason attached to a candidate the pass moved. */
const REASON_LABEL: Record<ConstraintKey, string> = {
  consecutiveCategory: 'category_diversity',
  consecutiveType: 'type_diversity',
  consecutiveAuthor: 'author_consecutive',
  authorPageCap: 'author_page_cap',
};

interface PassState {
  taken: ScoredCandidate[];
  authorCounts: Map<string, number>;
}

/** How many entries at the tail of `taken` share `value` under `read`. */
function trailingRun(
  taken: ScoredCandidate[],
  read: (c: ScoredCandidate) => string,
  value: string,
): number {
  let run = 0;
  for (let i = taken.length - 1; i >= 0; i--) {
    if (read(taken[i]) !== value) break;
    run++;
  }
  return run;
}

/**
 * EVERY constraint `item` would break in the current position — not just the
 * first one found.
 *
 * Returning the whole set is what fixes the failure mode a first-match-wins
 * version had: when a page is entirely one post type, `consecutiveType` blocks
 * every remaining candidate, and relaxing constraints in a fixed order would
 * drop `consecutiveCategory` — which was not the blocker — and admit a third
 * consecutive plumber that nothing had asked to allow. Scoring the full set
 * lets the caller break only what it must.
 */
function violations(
  item: ScoredCandidate,
  state: PassState,
  config: DiversityConfig,
): Set<ConstraintKey> {
  const broken = new Set<ConstraintKey>();
  const author = item.candidate.authorUserId;

  if (author) {
    const used = state.authorCounts.get(author) ?? 0;
    if (used >= Math.max(config.maxPerAuthorPerPage, 1)) broken.add('authorPageCap');

    const authorRun = trailingRun(state.taken, (c) => c.candidate.authorUserId, author);
    if (authorRun >= Math.max(config.maxConsecutiveSameAuthor, 1)) broken.add('consecutiveAuthor');
  }

  const category = item.candidate.category ?? '';
  const categoryRun = trailingRun(state.taken, (c) => c.candidate.category ?? '', category);
  if (categoryRun >= Math.max(config.maxConsecutiveSameCategory, 1)) {
    broken.add('consecutiveCategory');
  }

  const type = item.candidate.type ?? '';
  const typeRun = trailingRun(state.taken, (c) => c.candidate.type ?? '', type);
  if (typeRun >= Math.max(config.maxConsecutiveSameType, 1)) broken.add('consecutiveType');

  return broken;
}

/** Total cost of a violation set. 0 means the candidate is freely placeable. */
function violationCost(broken: Set<ConstraintKey>): number {
  let cost = 0;
  for (const key of broken) cost += CONSTRAINT_COST[key];
  return cost;
}

/** The most severe constraint in a set, for the explanation. */
function worstOf(broken: Set<ConstraintKey>): ConstraintKey | null {
  return BY_SEVERITY.find((key) => broken.has(key)) ?? null;
}

/**
 * Select up to `pageSize` items from `sorted` (already in descending score
 * order), honouring the diversity and anti-spam constraints.
 *
 * `startIndex` supports pagination: the pass runs over the whole scored list
 * and then slices, so page 2 inherits page 1's composition history rather than
 * starting fresh and repeating its opening pattern.
 */
export function diversify(
  sorted: ScoredCandidate[],
  config: DiversityConfig,
  pageSize: number,
  startIndex = 0,
): ScoredCandidate[] {
  const wanted = startIndex + Math.max(pageSize, 0);
  if (sorted.length === 0 || wanted <= 0) return [];

  const state: PassState = { taken: [], authorCounts: new Map() };
  const remaining = sorted.map((item, index) => ({ item, index }));

  while (state.taken.length < wanted && remaining.length > 0) {
    // Least-violation selection: prefer the highest-scoring candidate that
    // breaks nothing; failing that, the one whose violation set is CHEAPEST.
    // Relaxation is therefore per-position and minimal — a slot that can only
    // be filled by breaking `consecutiveType` breaks exactly that, and does not
    // also quietly permit a category or author violation nobody needed.
    let pickedAt = -1;
    let pickedCost = Number.POSITIVE_INFINITY;
    let pickedBroken: Set<ConstraintKey> = new Set();
    // What held back the top-ranked remaining candidate, for the explanation.
    let blockedBy: ConstraintKey | null = null;

    for (let i = 0; i < remaining.length; i++) {
      const broken = violations(remaining[i].item, state, config);
      const cost = violationCost(broken);

      if (i === 0 && cost > 0) blockedBy = worstOf(broken);

      if (cost === 0) {
        pickedAt = i;
        pickedCost = 0;
        pickedBroken = broken;
        break; // sorted by score, so the first clean candidate is the best one
      }
      // Strict `<` keeps the highest-scoring candidate on a cost tie.
      if (cost < pickedCost) {
        pickedAt = i;
        pickedCost = cost;
        pickedBroken = broken;
      }
    }

    if (pickedAt === -1) break; // remaining is non-empty, so unreachable

    const { item, index } = remaining.splice(pickedAt, 1)[0];

    // Record the move only when the pass actually changed this item's position.
    if (pickedAt > 0) {
      const reason = pickedCost > 0 ? worstOf(pickedBroken) : blockedBy;
      item.diversity = {
        movedFrom: index,
        reason: reason ? REASON_LABEL[reason] : 'diversity',
      };
    }

    state.taken.push(item);
    const author = item.candidate.authorUserId;
    if (author) state.authorCounts.set(author, (state.authorCounts.get(author) ?? 0) + 1);
  }

  return state.taken.slice(startIndex, wanted);
}
