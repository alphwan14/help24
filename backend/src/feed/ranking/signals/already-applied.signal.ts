import { FeedSignal } from '../types';

/**
 * Penalty — the viewer has already responded to this listing.
 *
 * The heaviest penalty in the engine (−30), heavier than the own-post one,
 * because a listing you already applied to is the single most useless thing a
 * recommendation feed can put in front of you: the action it invites is one you
 * cannot take again (`applications` has a unique constraint per post per
 * applicant, migration 029).
 *
 * Still a demotion rather than an exclusion. The card carries a real "Applied /
 * Offer sent" state that users check on — and a request whose author might yet
 * pick you is worth being able to find again.
 */
export const alreadyAppliedSignal: FeedSignal = {
  key: 'alreadyApplied',
  label: 'Already responded',

  weight: (config) => config.weights.alreadyApplied,

  score: (candidate) => (candidate.viewerHasApplied ? 1 : 0),
};
