import {
  FeedConfig,
  FeedSignal,
  RankingCandidate,
  ScoredCandidate,
  SignalContribution,
  SignalKey,
  ViewerContext,
} from './types';
import { FEED_SIGNALS } from './signal-registry';

/**
 * The scorer. It knows how to add up signals and nothing else — no signal's
 * meaning appears here, which is what keeps the model in `signal-registry.ts`
 * where it can be read in one screen.
 */

export interface ScoreOptions {
  /** Override the registry (tests, experiments, future A/B arms). */
  signals?: readonly FeedSignal[];
  /** Include each signal's `detail()` output. Costs a second call per signal. */
  explain?: boolean;
}

/** Round to 2 dp so explanations read cleanly and stay stable across platforms. */
function round2(value: number): number {
  return Math.round(value * 100) / 100;
}

/**
 * Score ONE candidate.
 *
 * A signal returning `null` means **not applicable** — it is recorded in
 * `skipped` and neither it nor its weight enters the total. That is the
 * difference between "this post is 0 km away from nowhere" and "we do not know
 * where you are", and getting it wrong is how feeds end up ranked by a signal
 * that had no information.
 *
 * A signal that throws is contained: it is skipped, the rest of the score still
 * computes. One bad signal must never blank a user's feed.
 */
export function scoreCandidate(
  candidate: RankingCandidate,
  viewer: ViewerContext,
  config: FeedConfig,
  options: ScoreOptions = {},
): ScoredCandidate {
  const signals = options.signals ?? FEED_SIGNALS;
  const contributions: SignalContribution[] = [];
  const skipped: SignalKey[] = [];
  let score = 0;

  for (const signal of signals) {
    let raw: number | null;
    try {
      raw = signal.score(candidate, viewer, config);
    } catch {
      skipped.push(signal.key);
      continue;
    }

    if (raw === null || raw === undefined || !Number.isFinite(raw)) {
      skipped.push(signal.key);
      continue;
    }

    const weight = signal.weight(config);
    const points = weight * raw;
    score += points;

    // A zero-point contribution is dropped from the explanation: "profession
    // +0" is noise, and an explanation nobody reads is not explainability.
    if (points === 0) continue;

    const contribution: SignalContribution = {
      key: signal.key,
      label: signal.label,
      weight,
      raw: round2(raw),
      points: round2(points),
    };

    if (options.explain && signal.detail) {
      try {
        contribution.detail = signal.detail(candidate, viewer, config);
      } catch {
        // An explanation that fails must not fail the request.
      }
    }

    contributions.push(contribution);
  }

  return { candidate, score: round2(score), contributions, skipped };
}

/**
 * Score and sort a candidate set.
 *
 * Cost is O(candidates × signals) — with the retrieval cap of 400 and 14
 * signals that is ~5 600 float operations, which is why this is nowhere near
 * the N² the brief warns against, and why it does not grow with the corpus.
 *
 * Ties break on `postId` rather than being left to the sort's stability. Two
 * candidates with identical scores must produce the same order on every run,
 * or pagination silently duplicates and drops rows between pages.
 */
export function scoreCandidates(
  candidates: RankingCandidate[],
  viewer: ViewerContext,
  config: FeedConfig,
  options: ScoreOptions = {},
): ScoredCandidate[] {
  const scored = candidates.map((c) => scoreCandidate(c, viewer, config, options));
  scored.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score;
    return a.candidate.postId.localeCompare(b.candidate.postId);
  });
  return scored;
}

/**
 * The highest score a candidate could theoretically reach under this config,
 * counting only positive weights. Used to render a 0–100 percentage in admin
 * tooling; it is NOT used in ranking, where raw points are what matter.
 */
export function maxPossibleScore(
  config: FeedConfig,
  signals: readonly FeedSignal[] = FEED_SIGNALS,
): number {
  return round2(signals.reduce((sum, s) => sum + Math.max(0, s.weight(config)), 0));
}
