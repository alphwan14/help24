import { RankingCandidate, ViewerContext, ViewerProfession } from './types';

/**
 * Fixture builders for the ranking specs.
 *
 * Every test starts from a NEUTRAL candidate and viewer and changes exactly one
 * thing. That is what makes a failure readable: if `distance.spec` breaks, the
 * only variable in play was distance.
 *
 * `NOW` is a fixed instant. The engine never reads the clock — `viewer.now` is
 * always injected — which is why these tests are reproducible rather than
 * flaky at midnight or across a DST boundary.
 */

export const NOW = new Date('2026-07-27T09:00:00.000Z');

export function makeCandidate(overrides: Partial<RankingCandidate> = {}): RankingCandidate {
  return {
    postId: overrides.postId ?? 'post-1',
    authorUserId: 'author-1',
    type: 'request',
    category: 'Plumbing',
    status: 'open',
    urgency: 'flexible',
    difficulty: 'medium',
    price: 1000,
    location: 'Nairobi',
    title: 'Fix a leaking kitchen tap',
    description: 'The tap under the sink drips constantly.',
    // 1 hour old: fresh enough that freshness is near 1 and does not mask
    // whatever the test is actually measuring.
    createdAt: new Date(NOW.getTime() - 3_600_000),
    isUrgent: false,
    urgentExpiresAt: null,
    latitude: null,
    longitude: null,
    distanceKm: null,
    authorProfession: null,
    authorIsVerified: false,
    authorAccountType: 'individual',
    authorAvailableUntil: null,
    authorLastSeen: null,
    bayesianRating: null,
    completionRate: null,
    disputeRate: null,
    totalReviews: null,
    completedJobs: null,
    tier: null,
    applicationCount: 0,
    saveCount: 0,
    messageCount: 0,
    viewCount: 0,
    viewerHasApplied: false,
    isOwnPost: false,
    pools: 'fresh',
    ...overrides,
  };
}

export function makeViewer(overrides: Partial<ViewerContext> = {}): ViewerContext {
  return {
    userId: 'viewer-1',
    latitude: null,
    longitude: null,
    professions: [],
    groupCategoryNames: new Map(),
    categoryAffinity: new Map(),
    professionAffinity: new Map(),
    authorAffinity: new Map(),
    recentSearches: [],
    localHour: 9,
    now: NOW,
    ...overrides,
  };
}

export function makeProfession(overrides: Partial<ViewerProfession> = {}): ViewerProfession {
  return {
    id: 'electrician',
    groupId: 'skilled-trades',
    categoryNames: ['Electrical'],
    tokens: ['electrician', 'fundi wa stima'],
    weight: 1,
    isPrimary: true,
    ...overrides,
  };
}

/** Hours before NOW, as a Date. */
export function hoursAgo(hours: number): Date {
  return new Date(NOW.getTime() - hours * 3_600_000);
}

/** Hours after NOW, as a Date. */
export function hoursAhead(hours: number): Date {
  return new Date(NOW.getTime() + hours * 3_600_000);
}
