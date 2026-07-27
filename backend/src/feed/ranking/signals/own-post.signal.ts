import { FeedSignal } from '../types';

/**
 * Penalty — the viewer's own listing.
 *
 * The brief's test of a good feed is "the posts they are most likely to
 * respond to, apply for, or hire from". Your own listing is never any of those.
 *
 * **Demoted, never hidden.** Excluding own posts would silently change what
 * Discover contains, and the product deliberately shows an owner their own
 * listing with an owner surface on it (see the listing-ownership contract). So
 * this is a −25 point penalty: an own post falls below comparable listings from
 * other people but is still reachable by scrolling, and still there when the
 * feed is thin.
 *
 * Implemented as a signal with a negative weight rather than as a special case
 * in the scorer, so it shows up in the explanation like everything else —
 * "ownPost −25" is a readable reason for a surprising position.
 */
export const ownPostSignal: FeedSignal = {
  key: 'ownPost',
  label: 'Your own listing',

  weight: (config) => config.weights.ownPost,

  // Binary: no partial ownership exists.
  score: (candidate) => (candidate.isOwnPost ? 1 : 0),
};
