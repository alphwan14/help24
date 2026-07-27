import { FeedSignal } from '../types';
import { clamp } from '../curves';
import { tokenize, tokensOf } from '../text-index';

/**
 * Signal 10 — Search history.
 *
 * "Recent searches influence Discover. Searching 'Laptop' should influence
 * recommendations for some time."
 *
 * *For some time* is the whole design. A search is a statement of intent with a
 * short shelf life — you wanted a laptop repaired on Tuesday, and by the
 * following month that is noise. So each stored query carries its own recency
 * weight (half-life 48 h, 7-day lookback, computed in `fn_user_affinity`),
 * separate from the 14-day half-life that governs behavioural affinity.
 *
 * Scoring is token coverage: what fraction of the query's words appear in the
 * post's title, description or category, scaled by how recent that query was.
 * The strongest single query wins rather than the sum, so someone who searched
 * five different things does not get a feed that is vaguely about all of them.
 *
 * Returns `null` when there is no recent search — most sessions — so the weight
 * leaves the calculation instead of flattening every candidate equally.
 */
export const searchHistorySignal: FeedSignal = {
  key: 'searchHistory',
  label: 'Recent searches',

  weight: (config) => config.weights.searchHistory,

  score: (candidate, viewer) => {
    if (viewer.recentSearches.length === 0) return null;

    const haystack = tokensOf(candidate);
    if (haystack.size === 0) return 0;

    let best = 0;
    for (const search of viewer.recentSearches) {
      const tokens = tokenize(search.query);
      if (tokens.length === 0) continue;

      const hits = tokens.filter((t) => haystack.has(t)).length;
      const coverage = hits / tokens.length;
      const scored = coverage * clamp(search.recency);
      if (scored > best) best = scored;
    }

    return clamp(best);
  },

  detail: (_candidate, viewer) => ({
    recentQueries: viewer.recentSearches.slice(0, 5).map((s) => s.query),
  }),
};
