import {
  ServingCandidate,
  applyRelevance,
  haversineKm,
  matchesCategory,
  matchesQuery,
  rankScore,
  rotationKey,
  selectSlots,
} from './serving-logic';

/**
 * Placement engine pure-logic tests. The core product guarantees under test:
 *  - relevance is NEVER bypassed (category / search / geo),
 *  - promotion never overrides geographic relevance,
 *  - quality (rating, completion, proximity) orders eligible campaigns,
 *  - rotation is deterministic per bucket and reshuffles across buckets,
 *  - slot caps hold.
 */

const NAIROBI = { lat: -1.286389, lng: 36.817223 };
const MOMBASA = { lat: -4.043477, lng: 39.668206 };

function candidate(over: Partial<ServingCandidate> = {}): ServingCandidate {
  return {
    campaignId: 'c-1',
    ownerUserId: 'u-1',
    post: {
      title: 'QuickFix Computer Repairs',
      description: 'Laptop and desktop repair, screen replacement.',
      category: 'Computer Repair',
      latitude: NAIROBI.lat,
      longitude: NAIROBI.lng,
    },
    bayesianRating: 4.5,
    completionRate: 0.9,
    ...over,
  };
}

const CTX = {
  placement: 'discover' as const,
  category: null,
  query: null,
  lat: null,
  lng: null,
  nearbyMaxRadiusKm: 30,
};

describe('haversineKm', () => {
  it('zero distance for identical points', () => {
    expect(haversineKm(NAIROBI.lat, NAIROBI.lng, NAIROBI.lat, NAIROBI.lng)).toBeCloseTo(0);
  });

  it('Nairobi ↔ Mombasa ≈ 440 km', () => {
    const d = haversineKm(NAIROBI.lat, NAIROBI.lng, MOMBASA.lat, MOMBASA.lng);
    expect(d).toBeGreaterThan(400);
    expect(d).toBeLessThan(480);
  });
});

describe('matchesCategory', () => {
  it('is case-insensitive and whitespace-tolerant', () => {
    expect(matchesCategory('Computer Repair', 'computer repair')).toBe(true);
    expect(matchesCategory(' Cleaning ', 'cleaning')).toBe(true);
  });

  it('never fuzzy-matches across categories', () => {
    expect(matchesCategory('Computer Repair', 'Repair')).toBe(false);
    expect(matchesCategory(null, 'Cleaning')).toBe(false);
  });
});

describe('matchesQuery — sponsored search stays precise', () => {
  const post = candidate().post;

  it('matches when every token appears (title/description/category)', () => {
    expect(matchesQuery(post, 'laptop repair')).toBe(true);
    expect(matchesQuery(post, 'QUICKFIX')).toBe(true);
    expect(matchesQuery(post, 'screen replacement')).toBe(true);
  });

  it('a plumber never surfaces for "laptop repair" (AND semantics)', () => {
    const plumber = { title: 'Reliable Plumber', description: 'Pipe repair', category: 'Plumbing' };
    expect(matchesQuery(plumber, 'laptop repair')).toBe(false);
    // ...but genuinely shared tokens still match
    expect(matchesQuery(plumber, 'repair')).toBe(true);
  });

  it('empty/blank query matches nothing', () => {
    expect(matchesQuery(post, '   ')).toBe(false);
  });
});

describe('applyRelevance — relevance is never bypassed', () => {
  it('category filter excludes other categories', () => {
    expect(applyRelevance(candidate(), { ...CTX, category: 'Cleaning' })).toBeNull();
    expect(applyRelevance(candidate(), { ...CTX, category: 'computer repair' })).not.toBeNull();
  });

  it('search filter excludes non-matching posts', () => {
    expect(applyRelevance(candidate(), { ...CTX, query: 'plumbing' })).toBeNull();
    expect(applyRelevance(candidate(), { ...CTX, query: 'laptop' })).not.toBeNull();
  });

  it('annotates distance when both sides have coordinates', () => {
    const c = applyRelevance(candidate(), { ...CTX, lat: NAIROBI.lat, lng: NAIROBI.lng });
    expect(c?.distanceKm).toBeCloseTo(0, 1);
  });

  it('promotion NEVER overrides geographic relevance: a Mombasa post is not served to a Nairobi viewer', () => {
    const mombasaPost = candidate({
      post: { ...candidate().post, latitude: MOMBASA.lat, longitude: MOMBASA.lng },
    });
    for (const placement of ['discover', 'search', 'category', 'nearby'] as const) {
      expect(
        applyRelevance(mombasaPost, { ...CTX, placement, lat: NAIROBI.lat, lng: NAIROBI.lng }),
      ).toBeNull();
    }
  });

  it("'nearby' requires verifiable proximity — no post coordinates → excluded", () => {
    const noCoords = candidate({ post: { ...candidate().post, latitude: null, longitude: null } });
    expect(
      applyRelevance(noCoords, { ...CTX, placement: 'nearby', lat: NAIROBI.lat, lng: NAIROBI.lng }),
    ).toBeNull();
  });

  it('other placements keep posts without coordinates (unknown ≠ far away)', () => {
    const noCoords = candidate({ post: { ...candidate().post, latitude: null, longitude: null } });
    const kept = applyRelevance(noCoords, { ...CTX, lat: NAIROBI.lat, lng: NAIROBI.lng });
    expect(kept).not.toBeNull();
    expect(kept?.distanceKm).toBeNull();
  });
});

describe('rankScore — quality still orders eligible campaigns', () => {
  it('is bounded in [0, 1]', () => {
    const best = candidate({ bayesianRating: 5, completionRate: 1, distanceKm: 0 });
    const worst = candidate({ bayesianRating: 0, completionRate: 0, distanceKm: 30 });
    expect(rankScore(best, 30)).toBeCloseTo(1);
    expect(rankScore(worst, 30)).toBeCloseTo(0);
  });

  it('higher rating outranks lower rating, all else equal', () => {
    const a = candidate({ bayesianRating: 4.9, completionRate: 0.9, distanceKm: 5 });
    const b = candidate({ bayesianRating: 3.0, completionRate: 0.9, distanceKm: 5 });
    expect(rankScore(a, 30)).toBeGreaterThan(rankScore(b, 30));
  });

  it('closer outranks farther, all else equal', () => {
    const near = candidate({ distanceKm: 1 });
    const far = candidate({ distanceKm: 25 });
    expect(rankScore(near, 30)).toBeGreaterThan(rankScore(far, 30));
  });

  it('unknown distance scores neutral — better than far, worse than near', () => {
    const unknown = rankScore(candidate({ distanceKm: null }), 30);
    expect(unknown).toBeLessThan(rankScore(candidate({ distanceKm: 0 }), 30));
    expect(unknown).toBeGreaterThan(rankScore(candidate({ distanceKm: 30 }), 30));
  });

  it('defends against out-of-range inputs', () => {
    const weird = candidate({ bayesianRating: 99, completionRate: 7, distanceKm: -3 });
    const s = rankScore(weird, 30);
    expect(s).toBeGreaterThanOrEqual(0);
    expect(s).toBeLessThanOrEqual(1.2); // proximity of negative distance clamps via min()
  });
});

describe('rotation — equal payers share exposure', () => {
  it('rotationKey is deterministic', () => {
    expect(rotationKey('abc', 42)).toBe(rotationKey('abc', 42));
  });

  it('rotationKey differs across buckets (reshuffles over time)', () => {
    expect(rotationKey('abc', 1)).not.toBe(rotationKey('abc', 2));
  });

  it('selectSlots is stable within a bucket (paging users see consistent slots)', () => {
    const pool = Array.from({ length: 9 }, (_, i) => candidate({ campaignId: `c-${i}` }));
    const a = selectSlots(pool, { maxSlots: 2, nearbyMaxRadiusKm: 30, bucket: 7 });
    const b = selectSlots(pool, { maxSlots: 2, nearbyMaxRadiusKm: 30, bucket: 7 });
    expect(a.map((c) => c.campaignId)).toEqual(b.map((c) => c.campaignId));
  });

  it('equal-quality campaigns all get exposure across buckets', () => {
    const pool = Array.from({ length: 3 }, (_, i) => candidate({ campaignId: `c-${i}` }));
    const served = new Set<string>();
    // 200 buckets ≈ 33 hours of 10-minute rotation windows.
    for (let bucket = 0; bucket < 200; bucket++) {
      for (const slot of selectSlots(pool, { maxSlots: 1, nearbyMaxRadiusKm: 30, bucket })) {
        served.add(slot.campaignId);
      }
    }
    expect(served.size).toBe(3);
  });

  it('quality gates pool entry: a clearly worse campaign never displaces the top pool', () => {
    // 3 strong candidates + 1 weak one; pool size for maxSlots=1 is 3 → weak
    // never enters rotation.
    const pool = [
      candidate({ campaignId: 'strong-1', bayesianRating: 4.8, completionRate: 0.95, distanceKm: 1 }),
      candidate({ campaignId: 'strong-2', bayesianRating: 4.7, completionRate: 0.93, distanceKm: 2 }),
      candidate({ campaignId: 'strong-3', bayesianRating: 4.6, completionRate: 0.9, distanceKm: 3 }),
      candidate({ campaignId: 'weak', bayesianRating: 1.0, completionRate: 0.1, distanceKm: 29 }),
    ];
    for (let bucket = 0; bucket < 40; bucket++) {
      const picked = selectSlots(pool, { maxSlots: 1, nearbyMaxRadiusKm: 30, bucket });
      expect(picked[0].campaignId).not.toBe('weak');
    }
  });
});

describe('slot caps', () => {
  it('never returns more than maxSlots', () => {
    const pool = Array.from({ length: 20 }, (_, i) => candidate({ campaignId: `c-${i}` }));
    expect(selectSlots(pool, { maxSlots: 3, nearbyMaxRadiusKm: 30, bucket: 1 })).toHaveLength(3);
    expect(selectSlots(pool, { maxSlots: 0, nearbyMaxRadiusKm: 30, bucket: 1 })).toHaveLength(0);
  });

  it('returns everything available when fewer candidates than slots', () => {
    expect(
      selectSlots([candidate()], { maxSlots: 3, nearbyMaxRadiusKm: 30, bucket: 1 }),
    ).toHaveLength(1);
  });
});
