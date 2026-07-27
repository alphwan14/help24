import { FeedSignal } from '../types';
import { rationalDecay } from '../curves';

/**
 * Signal 1 — Distance. The heaviest weight in the engine.
 *
 * Smooth rational decay, never a radius cut-off: a 21 km post scores slightly
 * below a 19 km one rather than vanishing. With the default curve
 * (halfPoint 15 km, steepness 1.5):
 *
 *     1 km → 0.98   5 km → 0.84   20 km → 0.39   100 km → 0.06
 *
 * Two null cases, and they mean opposite things:
 *
 *   * **the VIEWER has no coordinates** → `null`. Not applicable: the signal
 *     and its 30 points leave the calculation entirely, so a user who declined
 *     location permission gets a feed ranked on everything else rather than a
 *     feed where every post is uniformly 30 points poorer.
 *   * **the POST has no coordinates** → `unknownScore` (0.5). Unknown distance
 *     is not evidence of being far away; punishing it would bury every post
 *     created before geo capture existed.
 *
 * Distance always comes from real coordinates. City-string matching is a user
 * filter, never a proximity measure — see the audit, §3.2.
 */
export const distanceSignal: FeedSignal = {
  key: 'distance',
  label: 'Distance',

  weight: (config) => config.weights.distance,

  score: (candidate, viewer, config) => {
    const viewerHasCoords = viewer.latitude != null && viewer.longitude != null;
    if (!viewerHasCoords) return null;

    if (candidate.distanceKm == null) return config.distance.unknownScore;

    return rationalDecay(
      candidate.distanceKm,
      config.distance.halfPointKm,
      config.distance.steepness,
    );
  },

  detail: (candidate, viewer) => {
    if (viewer.latitude == null || viewer.longitude == null) return undefined;
    return {
      distanceKm: candidate.distanceKm == null ? null : Math.round(candidate.distanceKm * 100) / 100,
      postHasCoordinates: candidate.distanceKm != null,
    };
  },
};
