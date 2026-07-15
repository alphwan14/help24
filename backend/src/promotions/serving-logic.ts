/**
 * Placement-engine logic — the pure half of ServingService (no I/O, no Nest
 * imports; mirrors campaign-state.ts). ServingService fetches candidates and
 * delegates every decision here so relevance, ranking and rotation are unit-
 * testable without a database.
 *
 * Pipeline (spec §6): eligibility → relevance → ranking → rotation → cap.
 *
 * Ranking philosophy: promotion buys ENTRY into the slot auction among
 * eligible campaigns — quality (bayesian rating, completion rate, proximity)
 * still orders them. Promotion is a visibility signal, never a quality
 * override.
 */

export const PROMOTION_PLACEMENTS = ['discover', 'search', 'category', 'nearby'] as const;
export type PromotionPlacement = (typeof PROMOTION_PLACEMENTS)[number];

export function isPromotionPlacement(value: string): value is PromotionPlacement {
  return (PROMOTION_PLACEMENTS as readonly string[]).includes(value);
}

/** The subset of a post the relevance filter needs (full row rides along). */
export interface ServingPost {
  title?: string | null;
  description?: string | null;
  category?: string | null;
  latitude?: number | null;
  longitude?: number | null;
}

export interface ServingCandidate {
  campaignId: string;
  ownerUserId: string;
  post: ServingPost & Record<string, unknown>;
  /** provider_reputation.bayesian_rating (0–5); 0 when the provider has none. */
  bayesianRating: number;
  /** provider_reputation.completion_rate (0–1); 0 when the provider has none. */
  completionRate: number;
  /** Filled by the relevance pass when viewer coordinates are known. */
  distanceKm?: number | null;
}

export interface RelevanceContext {
  placement: PromotionPlacement;
  category?: string | null;
  query?: string | null;
  lat?: number | null;
  lng?: number | null;
  nearbyMaxRadiusKm: number;
}

// ── Geo ───────────────────────────────────────────────────────────────────────

const EARTH_RADIUS_KM = 6371;

export function haversineKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(a)));
}

// ── Relevance (never bypassed — spec: promotion never overrides relevance) ───

/** Case-insensitive exact category match (categories are a fixed registry). */
export function matchesCategory(postCategory: string | null | undefined, category: string): boolean {
  if (!postCategory) return false;
  return postCategory.trim().toLowerCase() === category.trim().toLowerCase();
}

/**
 * Search relevance: every query token must appear in the post's
 * title + description + category. AND-across-tokens keeps sponsored search
 * results precise — a plumber never surfaces for "laptop repair".
 */
export function matchesQuery(post: ServingPost, query: string): boolean {
  const tokens = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (tokens.length === 0) return false;
  const haystack = [post.title, post.description, post.category]
    .filter(Boolean)
    .join(' ')
    .toLowerCase();
  return tokens.every((t) => haystack.includes(t));
}

/**
 * Applies the relevance rules for one candidate and annotates distance.
 * Returns null when the candidate is not relevant for this request.
 *
 * Geo rule: 'nearby' REQUIRES post coordinates within the radius. Other
 * placements exclude posts that are provably outside the radius, but keep
 * posts without coordinates (distance unknowable → neutral, not punished).
 */
export function applyRelevance(
  candidate: ServingCandidate,
  ctx: RelevanceContext,
): ServingCandidate | null {
  const { post } = candidate;

  if (ctx.category && !matchesCategory(post.category, ctx.category)) return null;
  if (ctx.query && !matchesQuery(post, ctx.query)) return null;

  const viewerHasCoords = typeof ctx.lat === 'number' && typeof ctx.lng === 'number';
  const postHasCoords = typeof post.latitude === 'number' && typeof post.longitude === 'number';

  let distanceKm: number | null = null;
  if (viewerHasCoords && postHasCoords) {
    distanceKm = haversineKm(ctx.lat as number, ctx.lng as number, post.latitude as number, post.longitude as number);
  }

  if (ctx.placement === 'nearby') {
    if (distanceKm === null) return null; // nearby demands verifiable proximity
    if (distanceKm > ctx.nearbyMaxRadiusKm) return null;
  } else if (distanceKm !== null && distanceKm > ctx.nearbyMaxRadiusKm) {
    return null; // provably out of range — never serve a 300 km "nearby-ish" card
  }

  return { ...candidate, distanceKm };
}

// ── Ranking ───────────────────────────────────────────────────────────────────

/**
 * Composite quality score in [0, 1]:
 *   50% bayesian rating, 30% completion rate, 20% proximity.
 * Unknown distance scores neutral (0.5), not zero — a post without
 * coordinates is not evidence of being far away.
 */
export function rankScore(candidate: ServingCandidate, nearbyMaxRadiusKm: number): number {
  const rating = Math.max(0, Math.min(5, candidate.bayesianRating)) / 5;
  const completion = Math.max(0, Math.min(1, candidate.completionRate));
  const proximity =
    candidate.distanceKm == null
      ? 0.5
      : 1 - Math.min(candidate.distanceKm, nearbyMaxRadiusKm) / nearbyMaxRadiusKm;
  return 0.5 * rating + 0.3 * completion + 0.2 * proximity;
}

// ── Rotation ──────────────────────────────────────────────────────────────────

/**
 * Deterministic FNV-1a hash of campaign id + time bucket. Rotation must be
 * stable within a bucket (a user paging the same feed sees consistent slots)
 * yet reshuffle across buckets so equal payers share exposure over a day.
 */
export function rotationKey(campaignId: string, bucket: number): number {
  const input = `${campaignId}:${bucket}`;
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash;
}

/** How many top-ranked candidates compete for rotation per slot. */
const ROTATION_POOL_FACTOR = 3;

/**
 * Final selection: rank by quality, keep the top (maxSlots × 3) as the
 * rotation pool, then order the pool by the bucket-seeded hash and take
 * maxSlots. Quality gates entry into the pool; rotation shares exposure
 * fairly inside it.
 */
export function selectSlots(
  candidates: ServingCandidate[],
  params: { maxSlots: number; nearbyMaxRadiusKm: number; bucket: number },
): ServingCandidate[] {
  const { maxSlots, nearbyMaxRadiusKm, bucket } = params;
  if (maxSlots <= 0 || candidates.length === 0) return [];

  const ranked = [...candidates].sort(
    (a, b) => rankScore(b, nearbyMaxRadiusKm) - rankScore(a, nearbyMaxRadiusKm),
  );
  const pool = ranked.slice(0, Math.max(maxSlots * ROTATION_POOL_FACTOR, maxSlots));

  return pool
    .sort((a, b) => rotationKey(a.campaignId, bucket) - rotationKey(b.campaignId, bucket))
    .slice(0, maxSlots);
}
