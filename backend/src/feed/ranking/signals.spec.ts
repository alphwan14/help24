import { DEFAULT_FEED_CONFIG } from './defaults';
import { distanceSignal } from './signals/distance.signal';
import { professionSignal } from './signals/profession.signal';
import { skillsSignal } from './signals/skills.signal';
import { urgencySignal } from './signals/urgency.signal';
import { freshnessSignal } from './signals/freshness.signal';
import { engagementSignal } from './signals/engagement.signal';
import { availabilitySignal } from './signals/availability.signal';
import { reliabilitySignal, RELIABILITY_NEUTRAL } from './signals/reliability.signal';
import { behaviourSignal } from './signals/behaviour.signal';
import { searchHistorySignal } from './signals/search-history.signal';
import { timeOfDaySignal, isHourInWindow } from './signals/time-of-day.signal';
import { trustSignal } from './signals/trust.signal';
import { ownPostSignal } from './signals/own-post.signal';
import { alreadyAppliedSignal } from './signals/already-applied.signal';
import { FEED_SIGNALS } from './signal-registry';
import { makeCandidate, makeProfession, makeViewer, hoursAgo, hoursAhead } from './test-fixtures';

const CONFIG = DEFAULT_FEED_CONFIG;

/**
 * Signal-level tests — matrix rows 1–15, 25.
 *
 * Each block isolates ONE signal against the neutral fixture, so a failure
 * names the signal that broke rather than "the feed changed".
 */

describe('signal 1 — distance', () => {
  const viewer = makeViewer({ latitude: -1.2921, longitude: 36.8219 });

  // Matrix 1 + 2: the spec's own distance tiers, and no cliff at the far end.
  it.each([
    [1, 0.95, 1.0],
    [5, 0.8, 0.9],
    [20, 0.3, 0.45],
    [100, 0.02, 0.1],
  ])('%i km scores between %f and %f', (km, lo, hi) => {
    const score = distanceSignal.score(makeCandidate({ distanceKm: km }), viewer, CONFIG)!;
    expect(score).toBeGreaterThanOrEqual(lo);
    expect(score).toBeLessThanOrEqual(hi);
  });

  it('decays monotonically, so a nearer post always outranks a farther one', () => {
    const scores = [0.5, 1, 5, 10, 20, 50, 100, 500].map(
      (km) => distanceSignal.score(makeCandidate({ distanceKm: km }), viewer, CONFIG)!,
    );
    for (let i = 1; i < scores.length; i++) {
      expect(scores[i]).toBeLessThan(scores[i - 1]);
    }
  });

  it('scores exactly 0.5 at the configured half-point', () => {
    const score = distanceSignal.score(
      makeCandidate({ distanceKm: CONFIG.distance.halfPointKm }),
      viewer,
      CONFIG,
    );
    expect(score).toBeCloseTo(0.5, 6);
  });

  // Matrix 3: unknown distance is not evidence of being far away.
  it('scores a post without coordinates as neutral, not zero', () => {
    expect(distanceSignal.score(makeCandidate({ distanceKm: null }), viewer, CONFIG)).toBe(0.5);
  });

  it('ranks a post without coordinates above a provably distant one', () => {
    const unknown = distanceSignal.score(makeCandidate({ distanceKm: null }), viewer, CONFIG)!;
    const distant = distanceSignal.score(makeCandidate({ distanceKm: 120 }), viewer, CONFIG)!;
    expect(unknown).toBeGreaterThan(distant);
  });

  // Matrix 4: the "no location permission" case — the headline null-vs-zero rule.
  it('is NOT APPLICABLE when the viewer has no coordinates', () => {
    const noLocation = makeViewer({ latitude: null, longitude: null });
    expect(distanceSignal.score(makeCandidate({ distanceKm: 3 }), noLocation, CONFIG)).toBeNull();
  });
});

describe('signals 2 and 3 — profession and skills', () => {
  const groups = new Map([['skilled-trades', new Set(['plumbing', 'masonry'])]]);

  const electrician = makeViewer({
    professions: [makeProfession()],
    groupCategoryNames: groups,
  });

  // Matrix 5.
  it('scores an exact category match at full strength', () => {
    const score = professionSignal.score(
      makeCandidate({ category: 'Electrical' }),
      electrician,
      CONFIG,
    );
    expect(score).toBe(1);
  });

  // Matrix 7: the three tiers must stay strictly ordered.
  it('orders exact > group > text-token > none', () => {
    const exact = professionSignal.score(makeCandidate({ category: 'Electrical' }), electrician, CONFIG)!;
    const group = professionSignal.score(makeCandidate({ category: 'Masonry' }), electrician, CONFIG)!;
    const token = professionSignal.score(
      makeCandidate({ category: 'Catering', title: 'Need an electrician for the kitchen' }),
      electrician,
      CONFIG,
    )!;
    const none = professionSignal.score(makeCandidate({ category: 'Catering' }), electrician, CONFIG)!;

    expect(exact).toBeGreaterThan(group);
    expect(group).toBeGreaterThan(token);
    expect(token).toBeGreaterThan(none);
    expect(none).toBe(0);
  });

  it('matches a Kiswahili alias in the post text', () => {
    const score = professionSignal.score(
      makeCandidate({ category: 'Other', description: 'Nataka fundi wa stima leo' }),
      electrician,
      CONFIG,
    )!;
    expect(score).toBeGreaterThan(0);
  });

  // Matrix 6: an unset profession must not flatten the whole feed.
  it('is NOT APPLICABLE when the viewer has no profession', () => {
    expect(professionSignal.score(makeCandidate(), makeViewer(), CONFIG)).toBeNull();
  });

  it('scores 0 (not null) when a profession is set but nothing matches', () => {
    expect(
      professionSignal.score(makeCandidate({ category: 'Catering' }), electrician, CONFIG),
    ).toBe(0);
  });

  // Matrix 8.
  describe('skills', () => {
    const multiSkilled = makeViewer({
      professions: [
        makeProfession(),
        makeProfession({
          id: 'solar-technician',
          categoryNames: ['Electrical'],
          tokens: ['solar'],
          weight: 0.8,
          isPrimary: false,
        }),
        makeProfession({
          id: 'generator-repair',
          categoryNames: ['Mechanic'],
          tokens: ['generator'],
          weight: 0.5,
          isPrimary: false,
        }),
      ],
      groupCategoryNames: groups,
    });

    it('is NOT APPLICABLE when the user has no secondary skills', () => {
      expect(skillsSignal.score(makeCandidate(), makeViewer({ professions: [makeProfession()] }), CONFIG)).toBeNull();
    });

    it('picks the best-matching skill and scales it by that skill weight', () => {
      const score = skillsSignal.score(makeCandidate({ category: 'Mechanic' }), multiSkilled, CONFIG)!;
      expect(score).toBeCloseTo(0.5, 6); // exact match × the 0.5 skill weight
    });

    it('keeps the primary profession ahead of a secondary skill on the same post', () => {
      const post = makeCandidate({ category: 'Electrical' });
      const primaryPoints =
        professionSignal.score(post, multiSkilled, CONFIG)! * CONFIG.weights.profession;
      const skillPoints = skillsSignal.score(post, multiSkilled, CONFIG)! * CONFIG.weights.skills;
      expect(primaryPoints).toBeGreaterThan(skillPoints);
    });
  });
});

describe('signal 4 — urgency', () => {
  const viewer = makeViewer();

  const liveUrgent = (hoursOld: number) =>
    makeCandidate({
      isUrgent: true,
      urgency: 'urgent',
      createdAt: hoursAgo(hoursOld),
      urgentExpiresAt: hoursAhead(1),
    });

  // Matrix 9.
  it('decays across the spec tiers: 0 h huge, 3 h high, 12 h medium', () => {
    const at0 = urgencySignal.score(liveUrgent(0), viewer, CONFIG)!;
    const at3 = urgencySignal.score(liveUrgent(3), viewer, CONFIG)!;
    const at12 = urgencySignal.score(liveUrgent(12), viewer, CONFIG)!;

    expect(at0).toBe(1);
    expect(at3).toBeLessThan(at0);
    expect(at3).toBeGreaterThan(0.7);
    expect(at12).toBeLessThan(at3);
    expect(at12).toBeGreaterThan(0.3);
  });

  // Matrix 10 — the rule that keeps the urgent flag meaningful.
  it('drops the emergency boost entirely once the window has expired', () => {
    const expired = makeCandidate({
      isUrgent: true,
      urgency: 'urgent',
      createdAt: hoursAgo(1),
      urgentExpiresAt: hoursAgo(0.5),
    });
    const live = liveUrgent(1);

    expect(urgencySignal.score(expired, viewer, CONFIG)).toBe(CONFIG.urgency.enumScores.urgent);
    expect(urgencySignal.score(live, viewer, CONFIG)!).toBeGreaterThan(
      urgencySignal.score(expired, viewer, CONFIG)!,
    );
  });

  it('ranks the urgency enum urgent > soon > flexible for non-emergency posts', () => {
    const score = (urgency: string) => urgencySignal.score(makeCandidate({ urgency }), viewer, CONFIG)!;
    expect(score('urgent')).toBeGreaterThan(score('soon'));
    expect(score('soon')).toBeGreaterThan(score('flexible'));
    expect(score('flexible')).toBe(0);
  });

  it('never scores a decayed emergency below its own enum floor', () => {
    const old = liveUrgent(47); // anchors have almost run out
    expect(urgencySignal.score(old, viewer, CONFIG)!).toBeGreaterThanOrEqual(
      CONFIG.urgency.enumScores.urgent,
    );
  });
});

describe('signal 5 — freshness', () => {
  const viewer = makeViewer();

  // Matrix 11.
  it('scores exactly 0.5 at one half-life (24 h)', () => {
    const score = freshnessSignal.score(makeCandidate({ createdAt: hoursAgo(24) }), viewer, CONFIG);
    expect(score).toBeCloseTo(0.5, 6);
  });

  it('approaches but never reaches zero, so old posts stay reachable', () => {
    const ancient = freshnessSignal.score(
      makeCandidate({ createdAt: hoursAgo(24 * 365) }),
      viewer,
      CONFIG,
    )!;
    expect(ancient).toBeGreaterThanOrEqual(0);
    expect(ancient).toBeLessThan(0.001);
  });
});

describe('signal 6 — engagement', () => {
  const viewer = makeViewer();

  it('rewards intent signals, and ignores raw views entirely', () => {
    const viewed = engagementSignal.score(makeCandidate({ viewCount: 5000 }), viewer, CONFIG)!;
    const applied = engagementSignal.score(makeCandidate({ applicationCount: 2 }), viewer, CONFIG)!;
    expect(viewed).toBe(0);
    expect(applied).toBeGreaterThan(0);
  });

  // Matrix 12 — the "optimise for matches, not clicks" rule.
  it('scores an over-subscribed request BELOW a healthily-subscribed one', () => {
    const healthy = engagementSignal.score(makeCandidate({ applicationCount: 8 }), viewer, CONFIG)!;
    const crowded = engagementSignal.score(makeCandidate({ applicationCount: 30 }), viewer, CONFIG)!;
    expect(crowded).toBeLessThan(healthy);
  });

  it('does not apply the crowding penalty to offers', () => {
    const busyOffer = engagementSignal.score(
      makeCandidate({ type: 'offer', applicationCount: 30 }),
      viewer,
      CONFIG,
    )!;
    const quietOffer = engagementSignal.score(
      makeCandidate({ type: 'offer', applicationCount: 8 }),
      viewer,
      CONFIG,
    )!;
    expect(busyOffer).toBeGreaterThanOrEqual(quietOffer);
  });
});

describe('signal 7 — availability', () => {
  const viewer = makeViewer();

  // Matrix 15.
  it('is NOT APPLICABLE on requests and jobs', () => {
    expect(availabilitySignal.score(makeCandidate({ type: 'request' }), viewer, CONFIG)).toBeNull();
    expect(availabilitySignal.score(makeCandidate({ type: 'job' }), viewer, CONFIG)).toBeNull();
  });

  it('boosts an offer whose availability window is still open', () => {
    const score = availabilitySignal.score(
      makeCandidate({ type: 'offer', authorAvailableUntil: hoursAhead(2) }),
      viewer,
      CONFIG,
    );
    expect(score).toBe(CONFIG.availability.availableNowScore);
  });

  it('ignores an availability window that has already expired', () => {
    const stale = availabilitySignal.score(
      makeCandidate({ type: 'offer', authorAvailableUntil: hoursAgo(2), authorLastSeen: hoursAgo(2) }),
      viewer,
      CONFIG,
    )!;
    expect(stale).toBe(CONFIG.availability.activeWithin24hScore);
  });

  it('falls back to last-seen recency, descending', () => {
    const score = (hours: number | null) =>
      availabilitySignal.score(
        makeCandidate({ type: 'offer', authorLastSeen: hours === null ? null : hoursAgo(hours) }),
        viewer,
        CONFIG,
      )!;
    expect(score(1)).toBeGreaterThan(score(48));
    expect(score(48)).toBeGreaterThan(score(24 * 30));
    expect(score(null)).toBe(CONFIG.availability.staleScore);
  });
});

describe('signal 8 — reliability', () => {
  const viewer = makeViewer();

  // Matrix 13 — a marketplace that cannot give a first job has no supply side.
  it('scores a provider with no history as neutral, never zero', () => {
    expect(reliabilitySignal.score(makeCandidate(), viewer, CONFIG)).toBe(RELIABILITY_NEUTRAL);
  });

  it('holds a brand-new provider at neutral even with a perfect first impression', () => {
    const score = reliabilitySignal.score(
      makeCandidate({ bayesianRating: 5, completionRate: 1, disputeRate: 0, completedJobs: 0 }),
      viewer,
      CONFIG,
    )!;
    expect(score).toBeCloseTo(RELIABILITY_NEUTRAL, 6);
  });

  // Matrix 14.
  it('scores an established, flawless provider near the top', () => {
    const score = reliabilitySignal.score(
      makeCandidate({ bayesianRating: 5, completionRate: 1, disputeRate: 0, completedJobs: 50 }),
      viewer,
      CONFIG,
    )!;
    expect(score).toBeGreaterThan(0.95);
  });

  it('penalises a disputed record below the neutral baseline', () => {
    const score = reliabilitySignal.score(
      makeCandidate({ bayesianRating: 2, completionRate: 0.3, disputeRate: 0.5, completedJobs: 40 }),
      viewer,
      CONFIG,
    )!;
    expect(score).toBeLessThan(RELIABILITY_NEUTRAL);
  });
});

describe('signal 9 — behaviour', () => {
  it('is NOT APPLICABLE for a viewer with no history', () => {
    expect(behaviourSignal.score(makeCandidate(), makeViewer(), CONFIG)).toBeNull();
  });

  it('takes the strongest of category / profession / author affinity', () => {
    const viewer = makeViewer({
      categoryAffinity: new Map([['Plumbing', 0.4]]),
      authorAffinity: new Map([['author-1', 1]]),
    });
    // author 1.0 × 0.8 author factor = 0.8, which beats the 0.4 category pull.
    expect(behaviourSignal.score(makeCandidate(), viewer, CONFIG)).toBeCloseTo(0.8, 6);
  });

  it('discounts author affinity below an equal category affinity', () => {
    const byCategory = makeViewer({ categoryAffinity: new Map([['Plumbing', 1]]) });
    const byAuthor = makeViewer({ authorAffinity: new Map([['author-1', 1]]) });
    expect(behaviourSignal.score(makeCandidate(), byCategory, CONFIG)!).toBeGreaterThan(
      behaviourSignal.score(makeCandidate(), byAuthor, CONFIG)!,
    );
  });
});

describe('signal 10 — search history', () => {
  it('is NOT APPLICABLE with no recent searches', () => {
    expect(searchHistorySignal.score(makeCandidate(), makeViewer(), CONFIG)).toBeNull();
  });

  it('scores full token coverage of a fresh query at full strength', () => {
    const viewer = makeViewer({ recentSearches: [{ query: 'leaking tap', recency: 1 }] });
    const score = searchHistorySignal.score(
      makeCandidate({ title: 'Fix a leaking kitchen tap' }),
      viewer,
      CONFIG,
    )!;
    expect(score).toBe(1);
  });

  it('decays an older query below an identical fresh one', () => {
    const fresh = makeViewer({ recentSearches: [{ query: 'leaking tap', recency: 1 }] });
    const stale = makeViewer({ recentSearches: [{ query: 'leaking tap', recency: 0.1 }] });
    const post = makeCandidate({ title: 'Fix a leaking kitchen tap' });
    expect(searchHistorySignal.score(post, fresh, CONFIG)!).toBeGreaterThan(
      searchHistorySignal.score(post, stale, CONFIG)!,
    );
  });

  it('scores an unrelated post at zero', () => {
    const viewer = makeViewer({ recentSearches: [{ query: 'laptop repair', recency: 1 }] });
    expect(searchHistorySignal.score(makeCandidate(), viewer, CONFIG)).toBe(0);
  });
});

describe('signal 11 — time of day', () => {
  it('handles a window that wraps midnight', () => {
    const night = { hours: [21, 6] as [number, number], categories: [] };
    expect(isHourInWindow(23, night)).toBe(true);
    expect(isHourInWindow(3, night)).toBe(true);
    expect(isHourInWindow(12, night)).toBe(false);
  });

  it('boosts a category inside its window', () => {
    const morning = makeViewer({ localHour: 8 });
    expect(timeOfDaySignal.score(makeCandidate({ category: 'Plumbing' }), morning, CONFIG)).toBe(1);
  });

  it('never punishes an out-of-window category below the baseline floor', () => {
    const morning = makeViewer({ localHour: 8 });
    expect(timeOfDaySignal.score(makeCandidate({ category: 'Tutoring' }), morning, CONFIG)).toBe(
      CONFIG.timeOfDay.baseline,
    );
  });
});

describe('signal 14 — trust', () => {
  const viewer = makeViewer();

  it('gives an unverified individual newcomer no bonus and no penalty', () => {
    expect(trustSignal.score(makeCandidate(), viewer, CONFIG)).toBe(0);
  });

  it('rewards verification, business status and tier cumulatively', () => {
    const score = trustSignal.score(
      makeCandidate({
        authorIsVerified: true,
        authorAccountType: 'business',
        tier: 'trusted_professional',
      }),
      viewer,
      CONFIG,
    )!;
    expect(score).toBeCloseTo(1, 6);
  });

  it('orders the reputation tiers correctly', () => {
    const score = (tier: string) => trustSignal.score(makeCandidate({ tier }), viewer, CONFIG)!;
    expect(score('trusted_professional')).toBeGreaterThan(score('top_rated'));
    expect(score('top_rated')).toBeGreaterThan(score('rising_provider'));
    expect(score('rising_provider')).toBeGreaterThan(score('new_provider'));
  });

  it('treats an unknown tier as no bonus rather than crashing', () => {
    expect(trustSignal.score(makeCandidate({ tier: 'not_a_real_tier' }), viewer, CONFIG)).toBe(0);
  });
});

describe('penalties', () => {
  const viewer = makeViewer();

  it('fires only on the viewer own post', () => {
    expect(ownPostSignal.score(makeCandidate({ isOwnPost: true }), viewer, CONFIG)).toBe(1);
    expect(ownPostSignal.score(makeCandidate({ isOwnPost: false }), viewer, CONFIG)).toBe(0);
  });

  it('fires only when the viewer has already applied', () => {
    expect(alreadyAppliedSignal.score(makeCandidate({ viewerHasApplied: true }), viewer, CONFIG)).toBe(1);
    expect(alreadyAppliedSignal.score(makeCandidate({ viewerHasApplied: false }), viewer, CONFIG)).toBe(0);
  });

  it('carries negative weights, so firing always demotes', () => {
    expect(ownPostSignal.weight(CONFIG)).toBeLessThan(0);
    expect(alreadyAppliedSignal.weight(CONFIG)).toBeLessThan(0);
  });
});

describe('registry integrity', () => {
  it('has no duplicate signal keys', () => {
    const keys = FEED_SIGNALS.map((s) => s.key);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it('gives every registered signal a configured weight', () => {
    for (const signal of FEED_SIGNALS) {
      expect(typeof signal.weight(CONFIG)).toBe('number');
      expect(Number.isFinite(signal.weight(CONFIG))).toBe(true);
    }
  });

  // Matrix 25 — the fully cold viewer must not produce NaN anywhere.
  it('produces a finite 0..1 score or null for every signal on a bare candidate', () => {
    const bare = makeCandidate();
    const anonymous = makeViewer({ userId: null });
    for (const signal of FEED_SIGNALS) {
      const score = signal.score(bare, anonymous, CONFIG);
      if (score === null) continue;
      expect(Number.isFinite(score)).toBe(true);
      expect(score).toBeGreaterThanOrEqual(0);
      expect(score).toBeLessThanOrEqual(1);
    }
  });
});
