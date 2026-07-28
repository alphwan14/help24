import { DEFAULT_FEED_CONFIG } from './defaults';
import { bucketInstant } from './curves';
import { scoreCandidates } from './scorer';
import { distanceSignal } from './signals/distance.signal';
import { urgencySignal } from './signals/urgency.signal';
import { stalenessSignal } from './signals/staleness.signal';
import { makeCandidate, makeViewer, hoursAgo, hoursAhead, MOMBASA, NOW } from './test-fixtures';

const CONFIG = DEFAULT_FEED_CONFIG;

/**
 * REGRESSION — "Mombasa viewer, Nairobi post, five months old, ranked #1".
 *
 * Reported from production against the first generation of the engine. Three
 * independently defensible rules combined into an absurd result, and none of
 * the original 78 tests could catch it because each tested ONE signal against
 * a neutral fixture — the failure only exists in the interaction.
 *
 * The scenario is reproduced end-to-end at the bottom of this file. Do not
 * relax it: it is the cheapest guard the feed has against "each part is
 * correct and the whole is nonsense".
 */

const FIVE_MONTHS_HOURS = 24 * 150;

describe('regression: unknown distance must not beat known-far', () => {
  const viewer = makeViewer({
    ...MOMBASA,
    // Every candidate with coordinates is ~440 km away, so this is what a
    // typical post in this feed actually looks like.
    medianKnownDistanceKm: 440,
  });

  it('scores a coordinate-less post like a typical candidate, not like a near one', () => {
    const score = distanceSignal.score(makeCandidate({ distanceKm: null }), viewer, CONFIG)!;
    // Previously a flat 0.5 → 15 of 30 points, which beat every real post in
    // the country.
    expect(score).toBeLessThan(0.02);
  });

  it('does not let a coordinate-less post outrank a genuinely nearby one', () => {
    const unknown = distanceSignal.score(makeCandidate({ distanceKm: null }), viewer, CONFIG)!;
    const nearby = distanceSignal.score(makeCandidate({ distanceKm: 3 }), viewer, CONFIG)!;
    expect(nearby).toBeGreaterThan(unknown);
  });

  it('stays generous when the viewer is IN a dense area', () => {
    const local = makeViewer({ ...MOMBASA, medianKnownDistanceKm: 6 });
    const score = distanceSignal.score(makeCandidate({ distanceKm: null }), local, CONFIG)!;
    // Same rule, opposite outcome: near a busy city, unknown is still a
    // near-neutral score rather than a punishment.
    expect(score).toBeGreaterThan(0.7);
  });

  it('falls back to the configured constant when NO candidate has coordinates', () => {
    const blind = makeViewer({ ...MOMBASA, medianKnownDistanceKm: null });
    expect(distanceSignal.score(makeCandidate({ distanceKm: null }), blind, CONFIG)).toBe(
      CONFIG.distance.unknownScore,
    );
  });

  it('is still NOT APPLICABLE when the viewer has no location at all', () => {
    const noLocation = makeViewer({ medianKnownDistanceKm: 440 });
    expect(distanceSignal.score(makeCandidate({ distanceKm: null }), noLocation, CONFIG)).toBeNull();
  });
});

describe('regression: a stated urgency ages', () => {
  const viewer = makeViewer();

  it('gives an urgent post from five months ago essentially no urgency credit', () => {
    const ancient = makeCandidate({
      urgency: 'urgent',
      isUrgent: true,
      createdAt: hoursAgo(FIVE_MONTHS_HOURS),
      urgentExpiresAt: hoursAgo(FIVE_MONTHS_HOURS - 1), // long expired
    });
    // Previously a flat 0.5 → 9 of 18 points, forever.
    expect(urgencySignal.score(ancient, viewer, CONFIG)!).toBeLessThan(0.01);
  });

  it('still rewards a post marked urgent today', () => {
    const today = makeCandidate({
      urgency: 'urgent',
      isUrgent: true,
      createdAt: hoursAgo(2),
      urgentExpiresAt: hoursAgo(1), // window closed, but the claim is fresh
    });
    expect(urgencySignal.score(today, viewer, CONFIG)!).toBeGreaterThan(0.4);
  });

  it('leaves a LIVE emergency window on the anchor curve, undecayed', () => {
    const live = makeCandidate({
      urgency: 'urgent',
      isUrgent: true,
      createdAt: hoursAgo(0),
      urgentExpiresAt: hoursAhead(1),
    });
    expect(urgencySignal.score(live, viewer, CONFIG)).toBe(1);
  });

  it('decays monotonically across the enum fallback', () => {
    const at = (hours: number) =>
      urgencySignal.score(
        makeCandidate({
          urgency: 'urgent',
          isUrgent: true,
          createdAt: hoursAgo(hours),
          urgentExpiresAt: hoursAgo(hours - 1),
        }),
        viewer,
        CONFIG,
      )!;
    expect(at(2)).toBeGreaterThan(at(72));
    expect(at(72)).toBeGreaterThan(at(24 * 30));
    expect(at(24 * 30)).toBeGreaterThan(at(FIVE_MONTHS_HOURS));
  });
});

describe('regression: months-old open listings are treated as resolved', () => {
  const viewer = makeViewer();

  it('does not penalise anything inside the grace window', () => {
    expect(stalenessSignal.score(makeCandidate({ createdAt: hoursAgo(24 * 10) }), viewer, CONFIG)).toBe(0);
  });

  it('ramps rather than cliffs between the two thresholds', () => {
    const mid = stalenessSignal.score(makeCandidate({ createdAt: hoursAgo(24 * 60) }), viewer, CONFIG)!;
    expect(mid).toBeGreaterThan(0.4);
    expect(mid).toBeLessThan(0.6);
  });

  it('applies the full penalty to a five-month-old post', () => {
    expect(
      stalenessSignal.score(makeCandidate({ createdAt: hoursAgo(FIVE_MONTHS_HOURS) }), viewer, CONFIG),
    ).toBe(1);
  });

  it('demotes rather than removes — the penalty is a weight, not a filter', () => {
    expect(CONFIG.weights.staleness).toBeLessThan(0);
  });
});

describe('regression: the reported feed, end to end', () => {
  // A viewer in Mombasa. The corpus is Nairobi-centric and thin, which is what
  // let every neutral value dominate.
  const viewer = makeViewer({ ...MOMBASA, medianKnownDistanceKm: 440 });

  const nairobiUrgentAncient = makeCandidate({
    postId: 'nairobi-urgent-5mo',
    location: 'Nairobi',
    urgency: 'urgent',
    isUrgent: true,
    distanceKm: null, // no coordinates — the crux of the bug
    createdAt: hoursAgo(FIVE_MONTHS_HOURS),
    urgentExpiresAt: hoursAgo(FIVE_MONTHS_HOURS - 1),
  });

  const mombasaOrdinaryFresh = makeCandidate({
    postId: 'mombasa-normal-today',
    location: 'Mombasa',
    urgency: 'flexible',
    distanceKm: 4,
    createdAt: hoursAgo(3),
  });

  const nairobiOrdinaryFresh = makeCandidate({
    postId: 'nairobi-normal-today',
    location: 'Nairobi',
    urgency: 'flexible',
    distanceKm: 440,
    createdAt: hoursAgo(1),
  });

  it('does not put a five-month-old Nairobi post first for a Mombasa viewer', () => {
    const ranked = scoreCandidates(
      [nairobiUrgentAncient, mombasaOrdinaryFresh, nairobiOrdinaryFresh],
      viewer,
      CONFIG,
    );
    expect(ranked[0].candidate.postId).toBe('mombasa-normal-today');
    expect(ranked[ranked.length - 1].candidate.postId).toBe('nairobi-urgent-5mo');
  });

  it('ranks it last even when it is the ONLY urgent post in the set', () => {
    const ranked = scoreCandidates([nairobiUrgentAncient, nairobiOrdinaryFresh], viewer, CONFIG);
    expect(ranked[0].candidate.postId).toBe('nairobi-normal-today');
  });

  it('scores it negative — it is worse than nothing, not merely unlucky', () => {
    const ranked = scoreCandidates([nairobiUrgentAncient], viewer, CONFIG);
    expect(ranked[0].score).toBeLessThan(0);
  });

  it('still surfaces it rather than hiding it, when it is all there is', () => {
    const ranked = scoreCandidates([nairobiUrgentAncient], viewer, CONFIG);
    expect(ranked).toHaveLength(1);
  });

  it('explains itself: staleness is visible in the breakdown', () => {
    const ranked = scoreCandidates([nairobiUrgentAncient], viewer, CONFIG, { explain: true });
    const staleness = ranked[0].contributions.find((c) => c.key === 'staleness');
    expect(staleness).toBeDefined();
    expect(staleness!.points).toBeLessThan(0);
    expect(staleness!.detail).toMatchObject({ ageDays: 150 });
  });
});

/**
 * REGRESSION — "the feed reshuffles while I am reading it".
 *
 * Reported from production. Every time-dependent signal (freshness, urgency,
 * staleness, time-of-day) reads `ctx.now`, and `now` was a free-running wall
 * clock. Two requests seconds apart therefore scored every candidate slightly
 * differently, and any pair of posts within that epsilon traded places — so the
 * reader watched cards swap for no reason they could see.
 *
 * `rotationBucketMinutes` was declared in the config, seeded into the database
 * and documented as the determinism mechanism, but nothing ever read it. It
 * does now. These tests are what stop it becoming decorative again.
 */
describe('regression: ranking must not drift with the wall clock', () => {
  const viewer = makeViewer({ ...MOMBASA, medianKnownDistanceKm: 12 });

  // Deliberately near-tied: these are the pairs a drifting clock reorders.
  const corpus = [
    makeCandidate({ postId: 'a', distanceKm: 5.0, createdAt: hoursAgo(6) }),
    makeCandidate({ postId: 'b', distanceKm: 5.1, createdAt: hoursAgo(6.02) }),
    makeCandidate({ postId: 'c', distanceKm: 5.05, createdAt: hoursAgo(5.98) }),
    makeCandidate({ postId: 'd', distanceKm: 4.9, createdAt: hoursAgo(6.01), isUrgent: true, urgentExpiresAt: hoursAhead(1) }),
  ];

  const order = (now: Date) =>
    scoreCandidates(corpus, makeViewer({ ...MOMBASA, medianKnownDistanceKm: 12, now }), CONFIG).map(
      (r) => r.candidate.postId,
    );

  const BUCKET_MS = CONFIG.retrieval.rotationBucketMinutes * 60_000;

  it('returns an identical ordering everywhere inside one bucket', () => {
    const start = bucketInstant(NOW, CONFIG.retrieval.rotationBucketMinutes);
    const first = order(start);
    // Every second of the bucket, sampled — the client may re-ask at any of them.
    for (let offsetMs = 0; offsetMs < BUCKET_MS; offsetMs += 15_000) {
      const sampled = bucketInstant(
        new Date(start.getTime() + offsetMs),
        CONFIG.retrieval.rotationBucketMinutes,
      );
      expect(order(sampled)).toEqual(first);
    }
  });

  it('produces byte-identical scores, not merely the same order', () => {
    const start = bucketInstant(NOW, CONFIG.retrieval.rotationBucketMinutes);
    const later = bucketInstant(
      new Date(start.getTime() + BUCKET_MS - 1),
      CONFIG.retrieval.rotationBucketMinutes,
    );
    const a = scoreCandidates(corpus, makeViewer({ ...MOMBASA, medianKnownDistanceKm: 12, now: start }), CONFIG);
    const b = scoreCandidates(corpus, makeViewer({ ...MOMBASA, medianKnownDistanceKm: 12, now: later }), CONFIG);
    expect(b.map((r) => r.score)).toEqual(a.map((r) => r.score));
  });

  it('would have drifted without bucketing — the bug is real, not theoretical', () => {
    // Same corpus, same viewer, raw clock 9 minutes apart: at least one score
    // moves. This is what the reader was watching.
    const raw = (ms: number) =>
      scoreCandidates(
        corpus,
        makeViewer({ ...MOMBASA, medianKnownDistanceKm: 12, now: new Date(NOW.getTime() + ms) }),
        CONFIG,
      ).map((r) => r.score);
    expect(raw(9 * 60_000)).not.toEqual(raw(0));
  });

  it('never places the epoch in the future — a rounded bucket would expire live emergencies early', () => {
    for (const offsetMs of [0, 1, 60_000, BUCKET_MS - 1]) {
      const instant = new Date(NOW.getTime() + offsetMs);
      const bucketed = bucketInstant(instant, CONFIG.retrieval.rotationBucketMinutes);
      expect(bucketed.getTime()).toBeLessThanOrEqual(instant.getTime());
      expect(instant.getTime() - bucketed.getTime()).toBeLessThan(BUCKET_MS);
    }
  });

  it('lands on the bucket grid regardless of the instant given', () => {
    for (const offsetMs of [0, 1, 137_000, 599_999, 3_600_001]) {
      const bucketed = bucketInstant(new Date(NOW.getTime() + offsetMs), 10);
      expect(bucketed.getTime() % (10 * 60_000)).toBe(0);
    }
  });

  it('degrades to a one-minute grid rather than dividing by zero', () => {
    for (const bad of [0, -5, Number.NaN]) {
      expect(bucketInstant(NOW, bad).getTime() % 60_000).toBe(0);
    }
  });
});
