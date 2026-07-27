/**
 * Ranking engine — shared types.
 *
 * Everything in `ranking/` is PURE: no Nest imports, no I/O, no `Date.now()`
 * (the current instant is always passed in). That is what makes each of the
 * fifteen signals independently unit-testable, and it mirrors the shape that
 * already worked for `promotions/serving-logic.ts`.
 */

/** One candidate as returned by `fn_feed_candidates`, camelCased. */
export interface RankingCandidate {
  postId: string;
  authorUserId: string;
  type: 'request' | 'offer' | 'job' | string;
  category: string;
  status: string;
  urgency: 'urgent' | 'soon' | 'flexible' | string;
  difficulty: string | null;
  price: number;
  location: string;
  title: string;
  description: string;
  createdAt: Date;
  isUrgent: boolean;
  urgentExpiresAt: Date | null;
  latitude: number | null;
  longitude: number | null;
  /** Haversine km from the viewer; null when either side lacks coordinates. */
  distanceKm: number | null;

  // ── author ────────────────────────────────────────────────────────────────
  authorProfession: string | null;
  authorIsVerified: boolean;
  authorAccountType: string;
  authorAvailableUntil: Date | null;
  authorLastSeen: Date | null;

  // ── reputation (null = no history yet, which is NOT the same as zero) ──────
  bayesianRating: number | null;
  completionRate: number | null;
  disputeRate: number | null;
  totalReviews: number | null;
  completedJobs: number | null;
  tier: string | null;

  // ── engagement ────────────────────────────────────────────────────────────
  applicationCount: number;
  saveCount: number;
  messageCount: number;
  viewCount: number;

  // ── viewer relationship ───────────────────────────────────────────────────
  viewerHasApplied: boolean;
  isOwnPost: boolean;

  /** Comma-joined retrieval pools that surfaced this candidate. */
  pools: string;
}

/** A profession the viewer can serve, with the categories it maps to. */
export interface ViewerProfession {
  /** `professions.id` slug. */
  id: string;
  /** `professions.group_id`, when the catalogue provides one. */
  groupId: string | null;
  /** `categories.name` values this profession maps to (matches posts.category). */
  categoryNames: string[];
  /** Lowercased match tokens: the profession name plus its aliases. */
  tokens: string[];
  /** 1.0 for the primary profession; `user_skills.weight` for a secondary. */
  weight: number;
  /** `users.profession` (true) vs a `user_skills` row (false). */
  isPrimary: boolean;
}

/** A recent search, already decayed by age. */
export interface RecentSearch {
  /** Lowercased query text. */
  query: string;
  /** 0..1 recency weight (1 = just searched). */
  recency: number;
}

/**
 * Everything the engine knows about who is asking. Assembled once per request
 * by `ViewerContextService`; the signals never reach outside it.
 */
export interface ViewerContext {
  userId: string | null;
  latitude: number | null;
  longitude: number | null;
  /** Primary profession first, then secondary skills. */
  professions: ViewerProfession[];
  /**
   * `professions.group_id` → the lowercased category names reachable from that
   * group. Precomputed once per request so the group-match tier costs a set
   * lookup per candidate instead of a database round trip.
   */
  groupCategoryNames: Map<string, Set<string>>;
  /** categories.name → 0..1 behavioural affinity. */
  categoryAffinity: Map<string, number>;
  /** professions.id → 0..1 behavioural affinity. */
  professionAffinity: Map<string, number>;
  /** users.id → 0..1 behavioural affinity. */
  authorAffinity: Map<string, number>;
  recentSearches: RecentSearch[];
  /** Viewer-local hour, 0–23. Falls back to server UTC hour when unknown. */
  localHour: number;
  /** The instant the request is being served. Never read from the clock inside a signal. */
  now: Date;
}

// ── Configuration ───────────────────────────────────────────────────────────

export type SignalKey =
  | 'distance'
  | 'profession'
  | 'skills'
  | 'urgency'
  | 'freshness'
  | 'behaviour'
  | 'reliability'
  | 'searchHistory'
  | 'engagement'
  | 'availability'
  | 'trust'
  | 'timeOfDay'
  | 'ownPost'
  | 'alreadyApplied';

export type FeedWeights = Record<SignalKey, number>;

export interface DistanceConfig {
  halfPointKm: number;
  steepness: number;
  unknownScore: number;
}

export interface UrgencyConfig {
  /** `[hoursSinceCreated, score]` anchors, ascending by hours. */
  anchors: [number, number][];
  enumScores: Record<string, number>;
}

export interface FreshnessConfig {
  halfLifeHours: number;
}

export interface EngagementConfig {
  applicationsK: number;
  savesK: number;
  messagesK: number;
  applicationsWeight: number;
  savesWeight: number;
  messagesWeight: number;
  crowdThreshold: number;
}

export interface BehaviourConfig {
  halfLifeDays: number;
  lookbackDays: number;
  maxKeys: number;
  authorFactor: number;
  searchLookbackDays: number;
  searchHalfLifeHours: number;
  eventWeights: Record<string, number>;
}

export interface AvailabilityConfig {
  availableNowScore: number;
  activeWithin24hScore: number;
  activeWithin7dScore: number;
  staleScore: number;
}

export interface ReliabilityConfig {
  ratingWeight: number;
  completionWeight: number;
  disputeWeight: number;
  confidenceJobs: number;
}

export interface TrustConfig {
  verifiedWeight: number;
  businessWeight: number;
  tierWeight: number;
  tierScores: Record<string, number>;
}

export interface TimeOfDayWindow {
  /** `[startHourInclusive, endHourExclusive)`; may wrap midnight. */
  hours: [number, number];
  categories: string[];
}

export interface TimeOfDayConfig {
  baseline: number;
  windows: TimeOfDayWindow[];
}

export interface DiversityConfig {
  maxConsecutiveSameAuthor: number;
  maxPerAuthorPerPage: number;
  maxConsecutiveSameCategory: number;
  maxConsecutiveSameType: number;
}

export interface RetrievalConfig {
  poolLimit: number;
  maxCandidates: number;
  radiusKm: number;
  pageSize: number;
  maxPageSize: number;
  rotationBucketMinutes: number;
}

export interface FeedConfig {
  weights: FeedWeights;
  distance: DistanceConfig;
  urgency: UrgencyConfig;
  freshness: FreshnessConfig;
  engagement: EngagementConfig;
  behaviour: BehaviourConfig;
  availability: AvailabilityConfig;
  reliability: ReliabilityConfig;
  trust: TrustConfig;
  timeOfDay: TimeOfDayConfig;
  diversity: DiversityConfig;
  retrieval: RetrievalConfig;
}

// ── Signals ─────────────────────────────────────────────────────────────────

/**
 * One ranking signal.
 *
 * `score` returns 0..1, or **null meaning "not applicable"** — which removes
 * the signal AND its weight from this candidate's total. That distinction is
 * the reason a viewer who denied location permission gets a sensible feed
 * rather than one where every post lost the same 30 points: the signal simply
 * does not participate.
 *
 * `detail` is optional free-form context surfaced by `?explain=1`.
 */
export interface FeedSignal {
  key: SignalKey;
  /** Human-readable, shown in explanations and admin tooling. */
  label: string;
  weight(config: FeedConfig): number;
  score(candidate: RankingCandidate, viewer: ViewerContext, config: FeedConfig): number | null;
  detail?(
    candidate: RankingCandidate,
    viewer: ViewerContext,
    config: FeedConfig,
  ): Record<string, unknown> | undefined;
}

/** One signal's contribution to one candidate's score. */
export interface SignalContribution {
  key: SignalKey;
  label: string;
  weight: number;
  /** The 0..1 signal output. */
  raw: number;
  /** `weight × raw` — what actually moved the score. */
  points: number;
  detail?: Record<string, unknown>;
}

export interface ScoredCandidate {
  candidate: RankingCandidate;
  /** Σ points across applicable signals. */
  score: number;
  contributions: SignalContribution[];
  /** Signals that returned null, i.e. had no data to speak to this candidate. */
  skipped: SignalKey[];
  /** Set by the diversity pass when a candidate was moved from its score rank. */
  diversity?: { movedFrom: number; reason: string };
}
