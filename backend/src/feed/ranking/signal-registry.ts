import { FeedSignal } from './types';

import { distanceSignal } from './signals/distance.signal';
import { professionSignal } from './signals/profession.signal';
import { skillsSignal } from './signals/skills.signal';
import { urgencySignal } from './signals/urgency.signal';
import { freshnessSignal } from './signals/freshness.signal';
import { engagementSignal } from './signals/engagement.signal';
import { availabilitySignal } from './signals/availability.signal';
import { reliabilitySignal } from './signals/reliability.signal';
import { behaviourSignal } from './signals/behaviour.signal';
import { searchHistorySignal } from './signals/search-history.signal';
import { timeOfDaySignal } from './signals/time-of-day.signal';
import { trustSignal } from './signals/trust.signal';
import { ownPostSignal } from './signals/own-post.signal';
import { alreadyAppliedSignal } from './signals/already-applied.signal';
import { stalenessSignal } from './signals/staleness.signal';

/**
 * THE REGISTRY — the whole ranking model, in one readable list.
 *
 * The brief asked for this explicitly: *"Do NOT hardcode giant if-statements.
 * Design a modular ranking engine … each signal should be independently
 * testable."*
 *
 * Adding signal #16 is one file plus one line here. Removing one is deleting a
 * line. Reweighting one is a SQL update against `feed_settings` — no deploy.
 * Nothing in `scorer.ts` knows what any individual signal means.
 *
 * Order is presentational only (it is the order explanations are rendered in);
 * scoring is a sum, so it is order-independent by construction.
 */
export const FEED_SIGNALS: readonly FeedSignal[] = Object.freeze([
  // ── Relevance: why this post, for this person, here ─────────────────────
  distanceSignal, //      1  proximity, the heaviest weight
  professionSignal, //    2  primary trade ↔ post category
  skillsSignal, //        3  secondary trades (ships live, table empty)

  // ── Timeliness: why this post, now ──────────────────────────────────────
  urgencySignal, //       4  emergency boost that expires
  freshnessSignal, //     5  discovery for new posts
  timeOfDaySignal, //    11  a weak tilt, never a gate

  // ── Personalisation: what this person keeps choosing ────────────────────
  behaviourSignal, //     9  time-decayed affinity, no ML
  searchHistorySignal, // 10  short-lived intent from recent queries

  // ── Quality: who is on the other end ────────────────────────────────────
  reliabilitySignal, //   8  earned by delivering
  trustSignal, //        14  conferred by verification
  engagementSignal, //    6  intent over attention, crowding penalised
  availabilitySignal, //  7  offers only

  // ── Penalties: things that are never the opportunity ────────────────────
  ownPostSignal,
  alreadyAppliedSignal,
  stalenessSignal, //     a months-old "open" request was resolved offline
]);

/**
 * Signals 12 (category diversity), 13 (anti-spam) and 15 (sponsored content)
 * are deliberately absent. They are not scores — a post cannot be "more
 * diverse" on its own, only more diverse *given what is above it*. They are
 * composition rules and live in `diversity.ts` and (for sponsored) in the
 * client's already-shipped `FeedComposer`.
 */
