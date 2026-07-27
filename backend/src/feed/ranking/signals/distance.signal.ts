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
 * Two missing-data cases, and they mean opposite things:
 *
 *   * **the VIEWER has no coordinates** → `null`. Not applicable: the signal
 *     and its 30 points leave the calculation entirely, so a user who declined
 *     location permission gets a feed ranked on everything else rather than a
 *     feed where every post is uniformly 30 points poorer.
 *   * **the POST has no coordinates** → scored as if it were at the MEDIAN
 *     distance of the candidates that do have coordinates. Unknown distance is
 *     not evidence of being far away, so it must not be punished — but it is
 *     not evidence of being *near* either, which is what a fixed constant
 *     silently claimed.
 *
 * That second rule used to be a flat `unknownScore` of 0.5, i.e. "treat it as
 * 15 km away". Fine in a Nairobi-centric corpus; badly wrong for a viewer in
 * Mombasa, where every post with real coordinates is ~440 km away and scores
 * ~0.006, so any post MISSING coordinates collected 15 of 30 points and won
 * the feed outright. Anchoring to the set's own median makes "neutral" mean
 * *typical for this feed*: near a dense city it stays generous, far from
 * everything it correctly stops being a free pass. `unknownScore` remains the
 * fallback for the degenerate case where no candidate has coordinates at all.
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

    const km =
      candidate.distanceKm ??
      // No coordinates on the post: stand in the shoes of a typical candidate
      // in THIS feed, not at a fixed constant.
      viewer.medianKnownDistanceKm;

    // Degenerate case only — not one candidate in the set has coordinates, so
    // there is no median to anchor to and every post is equally unknowable.
    if (km == null) return config.distance.unknownScore;

    return rationalDecay(km, config.distance.halfPointKm, config.distance.steepness);
  },

  detail: (candidate, viewer) => {
    if (viewer.latitude == null || viewer.longitude == null) return undefined;
    return {
      distanceKm: candidate.distanceKm == null ? null : Math.round(candidate.distanceKm * 100) / 100,
      postHasCoordinates: candidate.distanceKm != null,
      // What an unknown-distance post was scored as, so a surprising position
      // is readable straight from the explanation.
      assumedKm:
        candidate.distanceKm != null || viewer.medianKnownDistanceKm == null
          ? null
          : Math.round(viewer.medianKnownDistanceKm * 100) / 100,
    };
  },
};
