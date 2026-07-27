import { FeedSignal } from '../types';
import { clamp } from '../curves';

/** Neutral score for a provider with no track record either way. */
export const RELIABILITY_NEUTRAL = 0.5;

/**
 * Signal 8 — Reliability. "Reliable providers deserve more visibility."
 *
 * Weighted over `provider_reputation` (migration 055), which is already the
 * product's single derived, idempotent, server-authoritative trust table — no
 * client-maintained counters anywhere in it. The audit found every one of these
 * numbers was fetched on each feed load purely to *display* a rating, and
 * contributed nothing to ordering. This is that data finally doing work.
 *
 *     0.50 × bayesian rating (÷5)
 *   + 0.35 × completion rate
 *   + 0.15 × (1 − dispute rate)
 *
 * **A new provider is never punished for being new.** The raw score is blended
 * toward neutral by `confidence = min(1, completed_jobs / 5)`, so:
 *
 *   * 0 completed jobs → exactly 0.5, the same as an average established
 *     provider — they compete on distance, profession and freshness like
 *     everyone else;
 *   * 5+ completed jobs → their record speaks for itself.
 *
 * A marketplace whose ranking makes it impossible to get a first job has no
 * supply side in twelve months.
 */
export const reliabilitySignal: FeedSignal = {
  key: 'reliability',
  label: 'Reliability',

  weight: (config) => config.weights.reliability,

  score: (candidate, _viewer, config) => {
    const cfg = config.reliability;

    // No reputation row at all → no evidence → neutral, not zero.
    if (candidate.bayesianRating == null && candidate.completionRate == null) {
      return RELIABILITY_NEUTRAL;
    }

    const rating = clamp((candidate.bayesianRating ?? 0) / 5);
    const completion = clamp(candidate.completionRate ?? 0);
    const disputeFree = clamp(1 - (candidate.disputeRate ?? 0));

    const raw = clamp(
      cfg.ratingWeight * rating + cfg.completionWeight * completion + cfg.disputeWeight * disputeFree,
    );

    const jobs = candidate.completedJobs ?? 0;
    const confidence = clamp(jobs / Math.max(cfg.confidenceJobs, 1));

    return clamp(confidence * raw + (1 - confidence) * RELIABILITY_NEUTRAL);
  },

  detail: (candidate, _viewer, config) => ({
    bayesianRating: candidate.bayesianRating,
    completionRate: candidate.completionRate,
    disputeRate: candidate.disputeRate,
    completedJobs: candidate.completedJobs ?? 0,
    confidence:
      Math.round(
        clamp((candidate.completedJobs ?? 0) / Math.max(config.reliability.confidenceJobs, 1)) * 100,
      ) / 100,
  }),
};
