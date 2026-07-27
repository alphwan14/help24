import { RankingCandidate } from './types';

/**
 * Lazily-built, per-candidate text views shared by every text-matching signal.
 *
 * Without this, `profession`, `skills` and `searchHistory` each lowercase (and
 * `searchHistory` also splits) the same title + description on every candidate,
 * every request — the dominant cost in the scoring loop, and it grows with the
 * number of skills a user has.
 *
 * A `WeakMap` keyed on the candidate object is the right cache here: entries
 * disappear with the request's candidate array, so nothing has to be
 * invalidated and nothing leaks between requests. Purity is preserved — the
 * same candidate always yields the same text.
 */

interface TextView {
  /** `title + description`, lowercased. Substring/alias matching. */
  haystack: string;
  /** Distinct tokens of `title + description + category`, ≥3 chars. */
  tokens: Set<string>;
}

const CACHE = new WeakMap<RankingCandidate, TextView>();

/** Tokens shorter than this carry no signal. */
const MIN_TOKEN_LENGTH = 3;

function build(candidate: RankingCandidate): TextView {
  const haystack = `${candidate.title ?? ''} ${candidate.description ?? ''}`.toLowerCase();
  const tokens = new Set(
    `${haystack} ${(candidate.category ?? '').toLowerCase()}`
      .split(/[^a-z0-9]+/)
      .filter((t) => t.length >= MIN_TOKEN_LENGTH),
  );
  return { haystack, tokens };
}

function view(candidate: RankingCandidate): TextView {
  let cached = CACHE.get(candidate);
  if (!cached) {
    cached = build(candidate);
    CACHE.set(candidate, cached);
  }
  return cached;
}

/** Lowercased `title + description` for substring matching. */
export function haystackOf(candidate: RankingCandidate): string {
  return view(candidate).haystack;
}

/** Distinct ≥3-char tokens of `title + description + category`. */
export function tokensOf(candidate: RankingCandidate): Set<string> {
  return view(candidate).tokens;
}

/** Split arbitrary text into the same token shape `tokensOf` produces. */
export function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length >= MIN_TOKEN_LENGTH);
}
