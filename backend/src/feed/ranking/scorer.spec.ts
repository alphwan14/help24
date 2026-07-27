import { DEFAULT_FEED_CONFIG } from './defaults';
import { scoreCandidate, scoreCandidates, maxPossibleScore } from './scorer';
import { diversify } from './diversity';
import { FeedSignal, RankingCandidate } from './types';
import { makeCandidate, makeProfession, makeViewer, hoursAgo, hoursAhead } from './test-fixtures';

const CONFIG = DEFAULT_FEED_CONFIG;

/**
 * Scorer, composition and end-to-end ordering — matrix rows 16–25.
 */

describe('scorer', () => {
  // Matrix 22 — an explanation that does not add up is not an explanation.
  it('sums its own explanation exactly', () => {
    const viewer = makeViewer({
      latitude: -1.29,
      longitude: 36.82,
      professions: [makeProfession()],
      categoryAffinity: new Map([['Electrical', 0.7]]),
      recentSearches: [{ query: 'wiring', recency: 0.9 }],
    });
    const result = scoreCandidate(
      makeCandidate({
        category: 'Electrical',
        distanceKm: 2,
        isUrgent: true,
        urgency: 'urgent',
        urgentExpiresAt: hoursAhead(1),
        authorIsVerified: true,
        applicationCount: 3,
        completedJobs: 20,
        bayesianRating: 4.8,
        completionRate: 0.95,
        disputeRate: 0,
      }),
      viewer,
      CONFIG,
    );

    const summed = result.contributions.reduce((total, c) => total + c.points, 0);
    expect(summed).toBeCloseTo(result.score, 1);
    expect(result.score).toBeGreaterThan(0);
  });

  it('records a not-applicable signal as skipped and excludes its weight', () => {
    const noLocation = makeViewer({ latitude: null, longitude: null });
    const result = scoreCandidate(makeCandidate({ distanceKm: 3 }), noLocation, CONFIG);

    expect(result.skipped).toContain('distance');
    expect(result.contributions.find((c) => c.key === 'distance')).toBeUndefined();
  });

  // Matrix 4, end to end: the whole point of null-vs-zero.
  it('ranks a location-less viewer feed on the remaining signals rather than flattening it', () => {
    const noLocation = makeViewer({ latitude: null, longitude: null, professions: [makeProfession()] });
    const ranked = scoreCandidates(
      [
        makeCandidate({ postId: 'far-electrical', category: 'Electrical', distanceKm: 900 }),
        makeCandidate({ postId: 'near-catering', category: 'Catering', distanceKm: 0.2 }),
      ],
      noLocation,
      CONFIG,
    );
    // Distance is unavailable, so profession decides — not a coin flip.
    expect(ranked[0].candidate.postId).toBe('far-electrical');
  });

  it('contains a throwing signal instead of failing the whole score', () => {
    const exploding: FeedSignal = {
      key: 'trust',
      label: 'Exploding',
      weight: () => 10,
      score: () => {
        throw new Error('boom');
      },
    };
    const registry = [exploding, ...[]] as FeedSignal[];
    const result = scoreCandidate(makeCandidate(), makeViewer(), CONFIG, { signals: registry });

    expect(result.score).toBe(0);
    expect(result.skipped).toContain('trust');
  });

  it('omits zero-point contributions from the explanation', () => {
    const result = scoreCandidate(makeCandidate({ urgency: 'flexible' }), makeViewer(), CONFIG);
    expect(result.contributions.every((c) => c.points !== 0)).toBe(true);
  });

  it('adds raw signal detail only when explain is requested', () => {
    const viewer = makeViewer({ latitude: -1.29, longitude: 36.82 });
    const post = makeCandidate({ distanceKm: 4 });

    const plain = scoreCandidate(post, viewer, CONFIG);
    const explained = scoreCandidate(post, viewer, CONFIG, { explain: true });

    expect(plain.contributions.find((c) => c.key === 'distance')?.detail).toBeUndefined();
    expect(explained.contributions.find((c) => c.key === 'distance')?.detail).toMatchObject({
      distanceKm: 4,
    });
  });

  // Matrix 19.
  it('is deterministic — 100 runs produce byte-identical output', () => {
    const viewer = makeViewer({ latitude: -1.29, longitude: 36.82, professions: [makeProfession()] });
    const candidates = Array.from({ length: 40 }, (_, i) =>
      makeCandidate({
        postId: `post-${i}`,
        authorUserId: `author-${i % 7}`,
        category: i % 2 === 0 ? 'Electrical' : 'Plumbing',
        distanceKm: (i % 13) + 1,
        createdAt: hoursAgo(i),
      }),
    );

    const baseline = JSON.stringify(
      scoreCandidates(candidates, viewer, CONFIG).map((s) => [s.candidate.postId, s.score]),
    );
    for (let run = 0; run < 100; run++) {
      const again = JSON.stringify(
        scoreCandidates(candidates, viewer, CONFIG).map((s) => [s.candidate.postId, s.score]),
      );
      expect(again).toBe(baseline);
    }
  });

  it('breaks score ties on post id so pagination cannot duplicate or drop rows', () => {
    const identical = ['zzz', 'aaa', 'mmm'].map((id) => makeCandidate({ postId: id }));
    const ranked = scoreCandidates(identical, makeViewer(), CONFIG);
    expect(ranked.map((r) => r.candidate.postId)).toEqual(['aaa', 'mmm', 'zzz']);
  });

  // Matrix 24.
  it('returns an empty list for an empty candidate set', () => {
    expect(scoreCandidates([], makeViewer(), CONFIG)).toEqual([]);
  });

  it('counts only positive weights toward the theoretical maximum', () => {
    const max = maxPossibleScore(CONFIG);
    expect(max).toBeGreaterThan(0);
    expect(max).toBe(
      Object.values(CONFIG.weights)
        .filter((w) => w > 0)
        .reduce((a, b) => a + b, 0),
    );
  });

  // Matrix 23.
  //
  // Asserts SCALING, not wall-clock. An absolute millisecond bound here was
  // flaky for the reason such bounds always are: Jest runs suites in parallel,
  // so the number measures how busy the machine is, and it failed the moment a
  // fifteenth signal joined the registry despite the code being no worse.
  //
  // The real risk is algorithmic — someone adding a signal that walks the
  // candidate set, turning O(n) into O(n²). A ratio catches exactly that and is
  // immune to contention, because both measurements suffer it equally.
  describe('performance', () => {
    const viewer = makeViewer({
      latitude: -1.29,
      longitude: 36.82,
      professions: [makeProfession()],
      medianKnownDistanceKm: 12,
    });

    const setOf = (n: number) =>
      Array.from({ length: n }, (_, i) =>
        makeCandidate({
          postId: `post-${i}`,
          authorUserId: `author-${i % 200}`,
          distanceKm: (i % 90) + 1,
          createdAt: hoursAgo(i % 500),
        }),
      );

    /** Best of 5 — the minimum is the run least disturbed by the scheduler. */
    const timeBestOf5 = (candidates: ReturnType<typeof setOf>) => {
      scoreCandidates(candidates, viewer, CONFIG); // warm the JIT
      let best = Infinity;
      for (let run = 0; run < 5; run++) {
        const startedAt = Date.now();
        scoreCandidates(candidates, viewer, CONFIG);
        best = Math.min(best, Date.now() - startedAt);
      }
      return Math.max(best, 1); // floor at 1 ms so the ratio cannot divide by 0
    };

    it('scales linearly with candidate count', () => {
      const small = timeBestOf5(setOf(1000));
      const large = timeBestOf5(setOf(5000));

      // 5× the work. Linear ≈ 5×, quadratic ≈ 25×. 12 separates them with room
      // for the sort's n log n and ordinary noise.
      expect(large / small).toBeLessThan(12);
    });

    it('stays far under the request budget at the production candidate cap', () => {
      // Retrieval caps at 400 (feed_settings.retrieval.maxCandidates), so this
      // is the size that actually runs on every request.
      expect(timeBestOf5(setOf(CONFIG.retrieval.maxCandidates))).toBeLessThan(50);
    });

    it('handles the full 5 000-candidate set without dropping any', () => {
      expect(scoreCandidates(setOf(5000), viewer, CONFIG)).toHaveLength(5000);
    });
  });
});

describe('end-to-end ordering', () => {
  const viewer = makeViewer({
    latitude: -1.29,
    longitude: 36.82,
    professions: [makeProfession()],
  });

  const rank = (candidates: RankingCandidate[]) =>
    scoreCandidates(candidates, viewer, CONFIG).map((s) => s.candidate.postId);

  it('puts a nearby, in-trade, urgent post first', () => {
    const order = rank([
      makeCandidate({ postId: 'ideal', category: 'Electrical', distanceKm: 1, isUrgent: true, urgency: 'urgent', urgentExpiresAt: hoursAhead(1) }),
      makeCandidate({ postId: 'near-wrong-trade', category: 'Catering', distanceKm: 1 }),
      makeCandidate({ postId: 'far-right-trade', category: 'Electrical', distanceKm: 80 }),
      makeCandidate({ postId: 'far-wrong-trade', category: 'Catering', distanceKm: 120 }),
    ]);
    expect(order[0]).toBe('ideal');
    expect(order[3]).toBe('far-wrong-trade');
  });

  // Matrix 20.
  it('demotes the viewer own post below an otherwise identical foreign post', () => {
    const order = rank([
      makeCandidate({ postId: 'mine', isOwnPost: true, distanceKm: 1, category: 'Electrical' }),
      makeCandidate({ postId: 'theirs', isOwnPost: false, distanceKm: 1, category: 'Electrical' }),
    ]);
    expect(order).toEqual(['theirs', 'mine']);
  });

  it('keeps the viewer own post in the feed rather than hiding it', () => {
    const only = rank([makeCandidate({ postId: 'mine', isOwnPost: true })]);
    expect(only).toEqual(['mine']);
  });

  // Matrix 21.
  it('demotes a listing the viewer already applied to', () => {
    const order = rank([
      makeCandidate({ postId: 'applied', viewerHasApplied: true, distanceKm: 1, category: 'Electrical' }),
      makeCandidate({ postId: 'open', viewerHasApplied: false, distanceKm: 1, category: 'Electrical' }),
    ]);
    expect(order).toEqual(['open', 'applied']);
  });

  it('lets a near, in-trade older post beat a distant, off-trade brand-new one', () => {
    const order = rank([
      makeCandidate({ postId: 'fresh-far', category: 'Catering', distanceKm: 150, createdAt: hoursAgo(0) }),
      makeCandidate({ postId: 'old-near', category: 'Electrical', distanceKm: 2, createdAt: hoursAgo(72) }),
    ]);
    // This single assertion is the reason the whole engine exists: recency
    // alone would have put 'fresh-far' first.
    expect(order[0]).toBe('old-near');
  });
});

describe('composition — diversity and anti-spam', () => {
  const viewer = makeViewer();

  // Matrix 16.
  it('caps one author at maxPerAuthorPerPage and never places two in a row', () => {
    const spam = Array.from({ length: 10 }, (_, i) =>
      makeCandidate({
        postId: `spam-${i}`,
        authorUserId: 'spammer',
        category: 'Plumbing',
        createdAt: hoursAgo(i * 0.01),
      }),
    );
    const others = Array.from({ length: 10 }, (_, i) =>
      makeCandidate({
        postId: `other-${i}`,
        authorUserId: `author-${i}`,
        category: i % 2 ? 'Catering' : 'Tutoring',
        createdAt: hoursAgo(50 + i),
      }),
    );

    const page = diversify(scoreCandidates([...spam, ...others], viewer, CONFIG), CONFIG.diversity, 10);
    const authors = page.map((p) => p.candidate.authorUserId);

    expect(authors.filter((a) => a === 'spammer').length).toBeLessThanOrEqual(
      CONFIG.diversity.maxPerAuthorPerPage,
    );
    for (let i = 1; i < authors.length; i++) {
      expect(authors[i] === authors[i - 1] && authors[i] === 'spammer').toBe(false);
    }
  });

  // Matrix 17.
  it('never places three consecutive posts of one category while alternatives exist', () => {
    const plumbers = Array.from({ length: 8 }, (_, i) =>
      makeCandidate({
        postId: `plumb-${i}`,
        authorUserId: `plumber-${i}`,
        category: 'Plumbing',
        createdAt: hoursAgo(i * 0.01),
      }),
    );
    const mixed = Array.from({ length: 8 }, (_, i) =>
      makeCandidate({
        postId: `mixed-${i}`,
        authorUserId: `mixed-${i}`,
        category: ['Catering', 'Tutoring', 'Electrical', 'Gardening'][i % 4],
        createdAt: hoursAgo(40 + i),
      }),
    );

    const page = diversify(
      scoreCandidates([...plumbers, ...mixed], viewer, CONFIG),
      CONFIG.diversity,
      12,
    );
    const categories = page.map((p) => p.candidate.category);

    let run = 1;
    for (let i = 1; i < categories.length; i++) {
      run = categories[i] === categories[i - 1] ? run + 1 : 1;
      expect(run).toBeLessThanOrEqual(CONFIG.diversity.maxConsecutiveSameCategory);
    }
  });

  // Matrix 18 — degrade to score order, never to a short page.
  it('returns a full page even when every candidate shares one author', () => {
    const monoculture = Array.from({ length: 12 }, (_, i) =>
      makeCandidate({ postId: `p-${i}`, authorUserId: 'only-author', category: 'Plumbing' }),
    );
    const page = diversify(scoreCandidates(monoculture, viewer, CONFIG), CONFIG.diversity, 10);
    expect(page).toHaveLength(10);
  });

  it('preserves score order when no constraint is ever triggered', () => {
    const varied = Array.from({ length: 6 }, (_, i) =>
      makeCandidate({
        postId: `p-${i}`,
        authorUserId: `author-${i}`,
        category: ['Plumbing', 'Catering', 'Tutoring', 'Electrical', 'Gardening', 'Laundry'][i],
        createdAt: hoursAgo(i),
      }),
    );
    const scored = scoreCandidates(varied, viewer, CONFIG);
    const page = diversify(scored, CONFIG.diversity, 6);
    expect(page.map((p) => p.candidate.postId)).toEqual(scored.map((s) => s.candidate.postId));
  });

  it('records why a candidate was moved from its score position', () => {
    const spam = Array.from({ length: 5 }, (_, i) =>
      makeCandidate({ postId: `spam-${i}`, authorUserId: 'spammer', category: 'Plumbing' }),
    );
    const filler = Array.from({ length: 5 }, (_, i) =>
      makeCandidate({
        postId: `filler-${i}`,
        authorUserId: `other-${i}`,
        category: 'Catering',
        createdAt: hoursAgo(80 + i),
      }),
    );

    const page = diversify(scoreCandidates([...spam, ...filler], viewer, CONFIG), CONFIG.diversity, 6);
    const moved = page.filter((p) => p.diversity);
    expect(moved.length).toBeGreaterThan(0);
    expect(moved[0].diversity!.reason).toMatch(/author|category|type|diversity/);
  });

  it('does not repeat page 1 composition on page 2', () => {
    const candidates = Array.from({ length: 30 }, (_, i) =>
      makeCandidate({
        postId: `p-${i}`,
        authorUserId: `author-${i % 5}`,
        category: ['Plumbing', 'Catering', 'Tutoring'][i % 3],
        createdAt: hoursAgo(i),
      }),
    );
    const scored = scoreCandidates(candidates, viewer, CONFIG);

    const page1 = diversify(scored, CONFIG.diversity, 10, 0).map((p) => p.candidate.postId);
    const page2 = diversify(scored, CONFIG.diversity, 10, 10).map((p) => p.candidate.postId);

    expect(page1).toHaveLength(10);
    expect(page2).toHaveLength(10);
    expect(page1.some((id) => page2.includes(id))).toBe(false);
  });

  it('returns nothing for a zero-size page', () => {
    expect(diversify(scoreCandidates([makeCandidate()], viewer, CONFIG), CONFIG.diversity, 0)).toEqual([]);
  });

  it('is deterministic across repeated composition passes', () => {
    const candidates = Array.from({ length: 25 }, (_, i) =>
      makeCandidate({
        postId: `p-${i}`,
        authorUserId: `author-${i % 4}`,
        category: ['Plumbing', 'Catering'][i % 2],
        createdAt: hoursAgo(i),
      }),
    );
    const first = diversify(scoreCandidates(candidates, viewer, CONFIG), CONFIG.diversity, 10).map(
      (p) => p.candidate.postId,
    );
    for (let i = 0; i < 20; i++) {
      const again = diversify(scoreCandidates(candidates, viewer, CONFIG), CONFIG.diversity, 10).map(
        (p) => p.candidate.postId,
      );
      expect(again).toEqual(first);
    }
  });
});
