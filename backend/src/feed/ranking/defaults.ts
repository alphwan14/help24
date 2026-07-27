/**
 * Compiled defaults for every tunable in the recommendation engine.
 *
 * `feed_settings` (migration 090) is merged OVER these, per key, with a type
 * check — so a missing table, a missing row, a missing key or a wrong-typed
 * value all degrade to the values here rather than to a broken feed. The seed
 * in 090 is byte-equivalent to this object, which is why applying that
 * migration changes no behaviour.
 *
 * When you change a number here, change it in 090's seed too — or the next
 * fresh database will disagree with production.
 */

import { FeedConfig } from './types';

export const DEFAULT_FEED_CONFIG: FeedConfig = {
  // Maximum points each signal can contribute. Negative entries are penalties.
  weights: {
    distance: 30,
    profession: 25,
    skills: 10,
    urgency: 18,
    freshness: 10,
    behaviour: 12,
    reliability: 8,
    searchHistory: 6,
    engagement: 5,
    availability: 5,
    trust: 5,
    timeOfDay: 4,
    ownPost: -25,
    alreadyApplied: -30,
    staleness: -22,
  },

  distance: {
    halfPointKm: 15,
    steepness: 1.5,
    unknownScore: 0.5,
  },

  urgency: {
    anchors: [
      [0, 1.0],
      [2, 0.85],
      [6, 0.6],
      [24, 0.25],
      [48, 0],
    ],
    enumScores: { urgent: 0.5, soon: 0.25, flexible: 0 },
    enumHalfLifeHours: 72,
  },

  freshness: {
    halfLifeHours: 24,
  },

  staleness: {
    staleAfterDays: 30,
    deadAfterDays: 90,
  },

  engagement: {
    applicationsK: 4,
    savesK: 5,
    messagesK: 5,
    applicationsWeight: 0.5,
    savesWeight: 0.3,
    messagesWeight: 0.2,
    crowdThreshold: 10,
  },

  behaviour: {
    halfLifeDays: 14,
    lookbackDays: 90,
    maxKeys: 20,
    authorFactor: 0.8,
    searchLookbackDays: 7,
    searchHalfLifeHours: 48,
    eventWeights: {
      hire: 8,
      apply: 5,
      message: 4,
      save: 3,
      search: 2,
      category_open: 1.5,
      open: 1,
      profile_open: 1,
      impression: 0.05,
      unsave: -3,
    },
  },

  availability: {
    availableNowScore: 1.0,
    activeWithin24hScore: 0.5,
    activeWithin7dScore: 0.35,
    staleScore: 0.15,
  },

  reliability: {
    ratingWeight: 0.5,
    completionWeight: 0.35,
    disputeWeight: 0.15,
    confidenceJobs: 5,
  },

  trust: {
    verifiedWeight: 0.4,
    businessWeight: 0.2,
    tierWeight: 0.4,
    tierScores: {
      trusted_professional: 1.0,
      highly_recommended: 0.8,
      top_rated: 0.6,
      rising_provider: 0.3,
      new_provider: 0.0,
    },
  },

  timeOfDay: {
    baseline: 0.35,
    windows: [
      { hours: [6, 11], categories: ['House Cleaning', 'Laundry', 'Plumbing', 'Electrical', 'Gardening'] },
      { hours: [11, 15], categories: ['Catering', 'Delivery Rider', 'Driver'] },
      { hours: [16, 21], categories: ['Tutoring', 'Security Guard', 'Babysitting'] },
      { hours: [21, 6], categories: ['Mechanic', 'Electrical', 'Plumbing', 'Security Guard'] },
    ],
  },

  diversity: {
    maxConsecutiveSameAuthor: 1,
    maxPerAuthorPerPage: 2,
    maxConsecutiveSameCategory: 2,
    maxConsecutiveSameType: 3,
  },

  retrieval: {
    poolLimit: 150,
    maxCandidates: 400,
    radiusKm: 60,
    pageSize: 20,
    maxPageSize: 50,
    rotationBucketMinutes: 10,
  },
};
