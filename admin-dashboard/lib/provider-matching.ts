/**
 * Who on Help24 could take a request — for an admin who has to phone someone,
 * because the dashboard cannot message users outside a dispute.
 *
 * The tiers are the backend's own (backend/src/feed/ranking/signals/
 * profession-match.ts), read from the same registry and turned around: the
 * feed asks "which posts suit this provider?", this asks "which providers suit
 * this post?".
 *
 *   same      the request's category is one the provider's trade maps to
 *             (professions.category_id → categories.name), or both name the
 *             same trade in the registry, or the provider has an open offer in
 *             that very category
 *   related   an adjacent trade — the same professions.group_id
 *   mentions  a word of the trade (its name or an alias, Kiswahili included)
 *             appears in the request, as a whole word — text evidence only
 *
 * A provider's trades come from their profile (users.profession, user_skills),
 * exactly as the feed builds them, and — here only — from their open offers:
 * an offer's category is resolved through the same registry by name, alias or
 * category, so an offer filed as "Delivery" (not a category name) still
 * reaches the delivery-rider trade. A label the registry cannot place at all
 * borrows the trades of a category that contains it ("Cleaning" → "House
 * Cleaning"), and that evidence is never stronger than "related".
 *
 * "Other" matches nothing: it is where a post goes when nothing fits.
 *
 * Distance comes only from real coordinates. When either side has none it is
 * unknown — never guessed from a town name.
 *
 * Pure (no I/O, no path aliases), so it also runs under plain Node.
 */

export type MatchTier = "same" | "related" | "mentions";

export const TIER_RANK: Record<MatchTier, number> = { same: 0, related: 1, mentions: 2 };

export interface ProfessionRow {
  id: string;
  name: string;
  group_id: string | null;
  category_id: string | null;
  aliases: string[] | null;
}

export interface CategoryRow {
  id: string;
  name: string;
}

export interface Registry {
  byId: Map<string, ProfessionRow>;
  /** categories.id → categories.name (what posts.category stores). */
  categoryNameById: Map<string, string>;
  /** Every category name, lowercased — for labels the registry does not know exactly. */
  categoryNames: string[];
  /** group → lowercased category names reachable from it (the backend's groupCategoryNames). */
  groupCategoryNames: Map<string, Set<string>>;
  /** Lowercased label → the trades it names: by profession name, alias, or the category a trade maps to. */
  tradesByLabel: Map<string, Set<string>>;
}

/** The backend's ViewerProfession, minus the feed-only weight. */
export interface Trade {
  id: string;
  /** The registry's name, or the legacy free text. */
  name: string;
  groupId: string | null;
  /** Lowercased category names this trade maps to. */
  categoryNames: string[];
  /** Lowercased name + aliases, at least three characters. */
  tokens: string[];
  /** Reached only through a word of a category name (see resolveLabel): never claims "same". */
  loose?: boolean;
}

export interface RequestLike {
  title: string | null;
  description: string | null;
  category: string | null;
  latitude: number | null;
  longitude: number | null;
  author_user_id: string | null;
}

export interface OfferLike {
  id: string;
  title: string | null;
  category: string | null;
  location: string | null;
  latitude: number | null;
  longitude: number | null;
  author_user_id: string | null;
  created_at: string;
}

export interface ProviderSeed {
  userId: string;
  /** users.profession and user_skills — the feed's own view of their trades. */
  professionIds: string[];
  /** Their open offers. */
  offers: OfferLike[];
}

export interface OfferMatch {
  offer: OfferLike;
  tier: MatchTier;
  distanceKm: number | null;
}

export interface Candidate {
  userId: string;
  /** The strongest evidence they have. */
  tier: MatchTier;
  /** The nearest matching offer that has coordinates. */
  distanceKm: number | null;
  /** Their matching open offers, best first. */
  offers: OfferMatch[];
  /** Their profile trade, when it matches. */
  profile: { trade: string; tier: MatchTier } | null;
}

const MATCHES_NOTHING = "other";
const MIN_TOKEN = 3;

/** Words that say nothing about which trade someone does. */
const GENERIC_WORDS = new Set([
  "services", "service", "general", "work", "works", "worker", "workers", "person", "people", "help", "helper",
  "expert", "professional", "specialist", "repair", "repairs", "fundi", "need", "needed", "looking", "wanted",
]);

function norm(s: string | null | undefined): string {
  return (s ?? "").trim().toLowerCase();
}

/**
 * Tokens for trade text the registry cannot place (a legacy free-text
 * profession, an offer label that names no category): the phrase itself plus
 * each distinctive word, so "Posho Mill Grinder" can reach a request about a
 * posho mill. Text evidence only — it never makes a match stronger than
 * "mentions".
 */
function freeTextTokens(text: string): string[] {
  const phrase = norm(text);
  const words = phrase.split(/[^a-z0-9]+/).filter((w) => w.length >= 4 && !GENERIC_WORDS.has(w));
  return [...new Set([phrase, ...words])].filter((t) => t.length >= MIN_TOKEN);
}

export function buildRegistry(professions: ProfessionRow[], categories: CategoryRow[]): Registry {
  const categoryNameById = new Map(categories.map((c) => [c.id, c.name] as const));
  const byId = new Map<string, ProfessionRow>();
  const groupCategoryNames = new Map<string, Set<string>>();
  const tradesByLabel = new Map<string, Set<string>>();

  const index = (label: string | null | undefined, id: string) => {
    const key = norm(label);
    if (!key || key === MATCHES_NOTHING) return;
    const ids = tradesByLabel.get(key) ?? new Set<string>();
    ids.add(id);
    tradesByLabel.set(key, ids);
  };

  for (const p of professions) {
    if (p.id === MATCHES_NOTHING) continue;
    byId.set(p.id, p);
    index(p.name, p.id);
    for (const alias of p.aliases ?? []) index(alias, p.id);
    const categoryName = p.category_id ? categoryNameById.get(p.category_id) : undefined;
    if (!categoryName) continue;
    index(categoryName, p.id);
    if (p.group_id) {
      const names = groupCategoryNames.get(p.group_id) ?? new Set<string>();
      names.add(norm(categoryName));
      groupCategoryNames.set(p.group_id, names);
    }
  }
  const categoryNames = categories.map((c) => norm(c.name)).filter((n) => n && n !== MATCHES_NOTHING);
  return { byId, categoryNameById, categoryNames, groupCategoryNames, tradesByLabel };
}

/**
 * The trades a category label names. `exact` when the registry knows the
 * label itself; otherwise `loose`: the trades of every category that contains
 * it as whole words, or that it contains — so a legacy "Cleaning" reaches the
 * trades of "House Cleaning". Loose evidence can make a trade related, never
 * the same work: "Repair" is in four categories and means none of them surely.
 */
export function resolveLabel(label: string | null | undefined, registry: Registry): { exact: Set<string>; loose: Set<string> } {
  const key = norm(label);
  const exact = new Set<string>();
  const loose = new Set<string>();
  if (!key || key === MATCHES_NOTHING) return { exact, loose };
  for (const id of registry.tradesByLabel.get(key) ?? []) exact.add(id);
  if (exact.size > 0) return { exact, loose };
  const words = wordsOf(key);
  for (const name of registry.categoryNames) {
    const nameWords = wordsOf(name);
    if (!nameWords.includes(words) && !words.includes(nameWords)) continue;
    for (const id of registry.tradesByLabel.get(name) ?? []) loose.add(id);
  }
  return { exact, loose };
}

/** The backend's toViewerProfession, unchanged in meaning. */
export function tradeOf(professionId: string, registry: Registry): Trade | null {
  const row = registry.byId.get(professionId);
  if (!row) {
    // A legacy free-text profession cannot map to a category, but its own
    // words still count as text evidence.
    const token = norm(professionId);
    if (token.length < MIN_TOKEN || token === MATCHES_NOTHING) return null;
    return { id: professionId, name: professionId.trim(), groupId: null, categoryNames: [], tokens: freeTextTokens(professionId) };
  }
  const categoryName = row.category_id ? registry.categoryNameById.get(row.category_id) : undefined;
  const tokens = [row.name, ...(row.aliases ?? [])].map(norm).filter((t) => t.length >= MIN_TOKEN);
  return {
    id: row.id,
    name: row.name,
    groupId: row.group_id,
    categoryNames: categoryName ? [norm(categoryName)] : [],
    tokens: [...new Set(tokens)],
  };
}

/** The trades an offer's category claims. A label the registry cannot place keeps its own words. */
function offerTrades(offer: OfferLike, registry: Registry): Trade[] {
  const label = norm(offer.category);
  if (!label || label === MATCHES_NOTHING) return [];
  const { exact, loose } = resolveLabel(label, registry);
  const trades: Trade[] = [];
  for (const id of exact) {
    const t = tradeOf(id, registry);
    if (t) trades.push(t);
  }
  for (const id of loose) {
    const t = tradeOf(id, registry);
    if (t) trades.push({ ...t, loose: true });
  }
  if (label.length >= MIN_TOKEN && exact.size === 0) {
    const name = (offer.category ?? "").trim();
    trades.push({ id: `label:${label}`, name, groupId: null, categoryNames: [], tokens: freeTextTokens(name) });
  }
  return trades;
}

interface RequestView {
  category: string;
  meaningful: boolean;
  /** Trades the request's own category names in the registry… */
  exact: Set<string>;
  /** …or only through a word of a category name. */
  loose: Set<string>;
  /** The request's words, space-separated and space-padded. */
  words: string;
}

/** " fix my burst pipe " — so a token matches whole words only. */
function wordsOf(text: string): string {
  return ` ${text.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean).join(" ")} `;
}

function mentions(words: string, token: string): boolean {
  const phrase = wordsOf(token);
  // The feed tests substrings; whole words here, or "rider" would put a
  // delivery rider on every request that says "provider".
  return phrase.trim().length >= MIN_TOKEN && words.includes(phrase);
}

function viewOf(request: RequestLike, registry: Registry): RequestView {
  const category = norm(request.category);
  const meaningful = category !== "" && category !== MATCHES_NOTHING;
  const { exact, loose } = resolveLabel(category, registry);
  return {
    category,
    meaningful,
    exact,
    loose,
    // The feed reads title + description. The category is added here so an
    // offer filed as "Cleaning" can reach a request filed as "House Cleaning".
    words: wordsOf(`${request.title ?? ""} ${request.description ?? ""} ${request.category ?? ""}`),
  };
}

function tierOf(r: RequestView, trades: Trade[], registry: Registry, offerCategory?: string | null): MatchTier | null {
  if (r.meaningful) {
    if (offerCategory != null && norm(offerCategory) === r.category) return "same";
    for (const t of trades) {
      if (t.loose) continue;
      if (t.categoryNames.includes(r.category) || r.exact.has(t.id)) return "same";
    }
    const requestTrades = [...r.exact, ...r.loose];
    for (const t of trades) {
      // The same trade, but one side only named it loosely.
      if (r.exact.has(t.id) || r.loose.has(t.id)) return "related";
      if (!t.groupId || t.groupId === MATCHES_NOTHING) continue;
      if (registry.groupCategoryNames.get(t.groupId)?.has(r.category)) return "related";
      for (const id of requestTrades) if (registry.byId.get(id)?.group_id === t.groupId) return "related";
    }
  }
  for (const t of trades) if (t.tokens.some((token) => mentions(r.words, token))) return "mentions";
  return null;
}

/** Great-circle distance in km, or null unless both sides have real coordinates. */
export function distanceKm(
  a: { latitude: number | null; longitude: number | null },
  b: { latitude: number | null; longitude: number | null },
): number | null {
  if (a.latitude == null || a.longitude == null || b.latitude == null || b.longitude == null) return null;
  const rad = (d: number) => (d * Math.PI) / 180;
  const dLat = rad(b.latitude - a.latitude);
  const dLng = rad(b.longitude - a.longitude);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.latitude)) * Math.cos(rad(b.latitude)) * Math.sin(dLng / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(h)));
}

function byTierThenDistance(a: { tier: MatchTier; distanceKm: number | null }, b: { tier: MatchTier; distanceKm: number | null }): number {
  if (a.tier !== b.tier) return TIER_RANK[a.tier] - TIER_RANK[b.tier];
  if (a.distanceKm != null && b.distanceKm != null) return a.distanceKm - b.distanceKm;
  // A known distance before an unknown one; an unknown one is not "far".
  if (a.distanceKm != null) return -1;
  if (b.distanceKm != null) return 1;
  return 0;
}

/** Everyone whose trade or open offers fit the request, strongest evidence first. The client is never suggested to themselves. */
export function candidatesFor(request: RequestLike, seeds: ProviderSeed[], registry: Registry): Candidate[] {
  const r = viewOf(request, registry);
  const out: Candidate[] = [];

  for (const seed of seeds) {
    if (seed.userId === request.author_user_id) continue;

    const offers: OfferMatch[] = [];
    for (const offer of seed.offers) {
      const tier = tierOf(r, offerTrades(offer, registry), registry, offer.category);
      if (tier) offers.push({ offer, tier, distanceKm: distanceKm(request, offer) });
    }

    let profile: Candidate["profile"] = null;
    for (const id of seed.professionIds) {
      const trade = tradeOf(id, registry);
      const tier = trade ? tierOf(r, [trade], registry) : null;
      if (trade && tier && (!profile || TIER_RANK[tier] < TIER_RANK[profile.tier])) profile = { trade: trade.name, tier };
    }

    if (offers.length === 0 && !profile) continue;
    offers.sort(byTierThenDistance);
    const tiers = [...offers.map((o) => o.tier), ...(profile ? [profile.tier] : [])];
    const best = tiers.reduce((a, b) => (TIER_RANK[b] < TIER_RANK[a] ? b : a));
    const known = offers.map((o) => o.distanceKm).filter((d): d is number => d != null);
    out.push({ userId: seed.userId, tier: best, distanceKm: known.length ? Math.min(...known) : null, offers, profile });
  }

  return out.sort((a, b) => byTierThenDistance(a, b) || b.offers.length - a.offers.length || a.userId.localeCompare(b.userId));
}

export function countByTier(candidates: Candidate[]): Record<MatchTier, number> {
  const counts: Record<MatchTier, number> = { same: 0, related: 0, mentions: 0 };
  for (const c of candidates) counts[c.tier] += 1;
  return counts;
}

/** "+254 712 345 678" for a Kenyan number; anything else as stored. */
export function fmtPhone(raw: string): string {
  const d = raw.replace(/\D/g, "");
  if (/^254\d{9}$/.test(d)) return `+254 ${d.slice(3, 6)} ${d.slice(6, 9)} ${d.slice(9)}`;
  if (/^0\d{9}$/.test(d)) return `${d.slice(0, 4)} ${d.slice(4, 7)} ${d.slice(7)}`;
  return raw.trim();
}

/** A tel: link, or null when the stored value is not a dialable number. */
export function telHref(raw: string): string | null {
  const d = raw.replace(/\D/g, "");
  if (/^254\d{9}$/.test(d)) return `tel:+${d}`;
  if (/^0\d{9}$/.test(d)) return `tel:+254${d.slice(1)}`;
  if (/^\d{7,15}$/.test(d)) return `tel:+${d}`;
  return null;
}
