import { RateLimitPolicy } from './rate-limit.types';

/**
 * THE RATE LIMIT CATALOGUE — every number in the system, in one file.
 *
 * HOW EACH LIMIT WAS DERIVED
 * --------------------------
 * No number below is a round figure someone liked. Each was produced by the
 * same three questions:
 *
 *   1. What does the CLIENT actually do? Where the mobile app polls on a
 *      timer, the interval was read out of the Flutter source rather than
 *      guessed — `payment_screen.dart` polls payment status every 5s,
 *      `interaction_tracker.dart` flushes telemetry every 8s,
 *      `job_status_card.dart` refreshes every 30s. A limit that a shipped
 *      client trips is a bug, not a control.
 *
 *   2. What does a PERSON plausibly do at the extreme? Not the average — the
 *      frustrated user retrying a failed payment, the provider applying to
 *      many jobs in one sitting. The limit sits above that, with headroom.
 *
 *   3. What does ABUSE look like, and is the gap wide enough? Abuse is
 *      typically two to four orders of magnitude above human behaviour, so a
 *      limit set at 5–10× the human extreme still stops it dead. Where that
 *      gap is narrow, the limit is tighter and the reason is stated.
 *
 * THE CGNAT CONSTRAINT (why IP limits look generous)
 * --------------------------------------------------
 * Safaricom and the other Kenyan mobile carriers put large numbers of
 * subscribers behind carrier-grade NAT. Hundreds of genuine Help24 users can
 * share one public IPv4 address, and a residential or campus Wi-Fi does the
 * same on a smaller scale. Every per-IP limit here is therefore sized for a
 * CROWD, not a person: it exists to stop one machine hammering the API, and it
 * must not turn a busy neighbourhood into a support ticket. The tight,
 * person-shaped limits are the per-subject rules.
 *
 * WHY SUBJECT RULES ARE STILL WORTH HAVING WHEN THE SUBJECT IS SPOOFABLE
 * ---------------------------------------------------------------------
 * This API takes identity from the request body, not from a verified token, so
 * an attacker can rotate `user_id` and evade any per-subject rule. They are
 * kept anyway because they stop the failure that actually happens far more
 * often than a determined attacker: a buggy client release, a retry loop, a
 * user hammering a button. The IP rule is the security boundary; the subject
 * rule is the correctness boundary. Both are needed.
 *
 * CHANGING A NUMBER
 * -----------------
 * Change it here and nowhere else. `@RateLimit('policy-name')` on a controller
 * carries no numbers, so a limit can be retuned without touching an endpoint,
 * and an endpoint can move without losing its limit.
 */

const SECOND = 1_000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;

/**
 * Applied to every route that does not declare a policy.
 *
 * Its job is to make "someone added an endpoint and forgot the decorator" a
 * degraded case rather than an unprotected one. Deliberately loose: it must
 * never be the thing that breaks a legitimate feature, because it applies to
 * code nobody considered. The tight limits live on the endpoints that earned
 * them.
 */
export const DEFAULT_POLICY_NAME = 'default';

export const RATE_LIMIT_POLICIES: readonly RateLimitPolicy[] = [
  {
    name: DEFAULT_POLICY_NAME,
    rationale:
      'Undeclared routes. Loose by design — a backstop against crude flooding, ' +
      'not a considered limit. 120/min per subject is roughly 10x the busiest ' +
      'observed client screen; 900 burst / 600 per min per IP tolerates a large ' +
      'CGNAT population while still stopping a single host from sustaining more ' +
      'than 10 requests a second.',
    rules: [
      {
        id: 'subject',
        algorithm: 'token-bucket',
        by: ['auth.uid', 'body.user_id', 'query.user_id'],
        capacity: 120,
        refillTokens: 120,
        refillIntervalMs: MINUTE,
      },
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 900,
        refillTokens: 600,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // READ PATHS — high volume, cheap per call, polled by the client
  // ═══════════════════════════════════════════════════════════════════════════

  {
    name: 'feed:read',
    rationale:
      'GET /feed (which is also the SEARCH surface — the query travels as a ' +
      'feed filter) and the promotion slots called alongside it. A screen open ' +
      'costs 2 requests; pull-to-refresh and each filter change cost 2 more. An ' +
      'energetic user might do 20 refreshes in a minute. Bucket, not window: ' +
      'the burst on cold start is legitimate and a flat per-minute cap would ' +
      'reject it. 90 burst / 60 per min leaves ~3x headroom over that user, ' +
      'while ranking is the most expensive read in the system so the sustained ' +
      'rate stays bounded.',
    rules: [
      {
        id: 'subject',
        algorithm: 'token-bucket',
        by: ['auth.uid', 'query.user_id', 'body.user_id'],
        capacity: 90,
        refillTokens: 60,
        refillIntervalMs: MINUTE,
      },
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 900,
        refillTokens: 600,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  {
    name: 'jobs:read',
    rationale:
      'Job status and lifecycle reads. job_status_card.dart refreshes on a 30s ' +
      'adaptive timer, so a user watching several active jobs generates a few ' +
      'calls a minute. 60 burst / 60 per min is an order of magnitude above ' +
      'that and still caps enumeration of job state.',
    rules: [
      {
        id: 'subject',
        algorithm: 'token-bucket',
        by: ['auth.uid', 'query.user_id', 'body.user_id'],
        capacity: 60,
        refillTokens: 60,
        refillIntervalMs: MINUTE,
      },
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 600,
        refillTokens: 400,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  {
    name: 'general:read',
    rationale:
      'Moderate-volume authenticated reads that are not the feed: reputation ' +
      'and review lookups while browsing provider profiles, a promoter`s own ' +
      'campaign list, payment history, campaign analytics, review eligibility. ' +
      'Scrolling a list and opening several profiles is a natural burst, so the ' +
      'capacity is high and the sustained rate moderate. One policy rather than ' +
      'six near-identical ones — they share a cost profile and a threat model ' +
      '(bulk scraping of the provider directory), and splitting them would add ' +
      'names without adding protection.',
    rules: [
      {
        id: 'subject',
        algorithm: 'token-bucket',
        by: ['auth.uid', 'query.user_id'],
        capacity: 120,
        refillTokens: 90,
        refillIntervalMs: MINUTE,
      },
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 900,
        refillTokens: 600,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  {
    name: 'config:read',
    rationale:
      'GET /config — the client bootstrap document (kill switches, maintenance ' +
      'notice, version gates). remote_config_service.dart fetches on cold start ' +
      'and on resume behind a 15-minute TTL, so one device costs ~4 requests an ' +
      'hour, and the steady state is a 304 with an empty body. ' +
      'ONE RULE, AND DELIBERATELY NOT THE USUAL SUBJECT+IP PAIR. This document ' +
      'is identical for every caller and is read mostly by clients with no ' +
      'identity attached — signed-out users, and every client during the first ' +
      'moments of a cold start. `resolveIdentity` keys a subject rule on ' +
      '`fallback-ip:<ip>` when no user_id resolves, so a person-sized subject ' +
      'rule silently becomes a person-sized limit on a CGNAT ADDRESS: hundreds ' +
      'of Safaricom subscribers sharing one public IPv4 would contend for one ' +
      'small bucket. That is the wrong failure for the one endpoint that has to ' +
      'answer during an incident, when every device is relaunching at once — ' +
      'and this is precisely the surface an operator reaches for to stop the ' +
      'incident. So the limit is a single crowd-sized IP rule: it still stops ' +
      'one host hammering the API (2400/min is 40 requests a second sustained, ' +
      'far above any legitimate client and above a spin loop worth absorbing), ' +
      'while never turning a busy neighbourhood into a support ticket.',
    rules: [
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 3000,
        refillTokens: 2400,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  {
    name: 'telemetry:ingest',
    rationale:
      'Batched behavioural events and promotion impression/click events. ' +
      'interaction_tracker.dart flushes every 8s (7.5/min) and batches within ' +
      'that window, so 30 burst / 20 per min is ~3x the shipped client. These ' +
      'writes are unauthenticated and land in analytics tables, so the ceiling ' +
      'also bounds how fast someone can pollute the ranking signal — a real ' +
      'concern, since behavioural events feed the recommendation engine.',
    rules: [
      {
        id: 'subject',
        algorithm: 'token-bucket',
        by: ['auth.uid', 'body.user_id'],
        capacity: 30,
        refillTokens: 20,
        refillIntervalMs: MINUTE,
      },
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 400,
        refillTokens: 240,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // WRITE PATHS — low volume, each one changes state a person can see
  // ═══════════════════════════════════════════════════════════════════════════

  {
    name: 'jobs:action',
    rationale:
      'Selecting a provider, marking complete, approving, archiving, notifying ' +
      'an application. These are deliberate human decisions: a very busy client ' +
      'might take a dozen such actions in ten minutes. 30 per 10 min per person ' +
      'is generous for that and still caps notification spam, since several of ' +
      'these send a push to the other party. Sliding window, not bucket — there ' +
      'is no legitimate burst here, so exactness is worth more than tolerance.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid', 'body.user_id', 'body.applicant_user_id', 'body.client_user_id'],
        windowMs: 10 * MINUTE,
        limit: 30,
      },
      {
        id: 'ip',
        algorithm: 'sliding-window',
        by: 'ip',
        windowMs: 10 * MINUTE,
        limit: 300,
      },
    ],
  },

  {
    name: 'messaging:notify',
    rationale:
      'The push-notification hook the app calls after inserting a chat message. ' +
      'A fast typer sends maybe 20 short messages a minute; 40 burst / 30 per ' +
      'min covers that with headroom. This is the ONE endpoint where the limit ' +
      'protects a third party rather than the server: every call fires an FCM ' +
      'push at another person`s phone, so an unbounded version is a harassment ' +
      'tool and a way to burn FCM quota. Note the message itself is written ' +
      'client-side to Supabase — this limit throttles the NOTIFICATION, not the ' +
      'message (see the security report).',
    rules: [
      {
        id: 'subject',
        algorithm: 'token-bucket',
        by: ['auth.uid', 'body.senderId'],
        capacity: 40,
        refillTokens: 30,
        refillIntervalMs: MINUTE,
      },
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 400,
        refillTokens: 300,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  {
    name: 'availability:toggle',
    rationale:
      '"Available now" is a switch a provider flips a handful of times a day. ' +
      '30 per hour is far above any real use and stops the toggle being used to ' +
      'churn a ranking signal.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid', 'body.user_id'],
        windowMs: HOUR,
        limit: 30,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 200 },
    ],
  },

  {
    name: 'reviews:write',
    rationale:
      'A review requires a completed job, so eligibility already bounds this ' +
      'hard. 10 per hour is above any plausible honest rate and exists to stop ' +
      'a scripted attempt to farm reputation across many stolen job ids.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid', 'body.reviewer_user_id', 'body.user_id'],
        windowMs: HOUR,
        limit: 10,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 60 },
    ],
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // MONEY — the endpoints where an extra request costs real shillings
  // ═══════════════════════════════════════════════════════════════════════════

  {
    name: 'payments:initiate',
    rationale:
      'STK push. Every call pushes a PIN prompt onto a real phone and consumes ' +
      'Daraja quota. A user paying for a job needs one; a user whose first ' +
      'attempt failed might reasonably retry three or four times. 5 per 10 min ' +
      'per payer covers the frustrated case exactly and nothing beyond it. ' +
      'The IP rule (60 per 10 min) is what actually stops prompt-spamming, ' +
      'since the payer id is asserted rather than proven — it allows a busy ' +
      'shared connection while capping one host at 6 prompts a minute.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid', 'body.buyer_user_id', 'body.user_id'],
        windowMs: 10 * MINUTE,
        limit: 5,
      },
      {
        id: 'ip',
        algorithm: 'sliding-window',
        by: 'ip',
        windowMs: 10 * MINUTE,
        limit: 60,
      },
    ],
  },

  {
    name: 'payments:read',
    rationale:
      'Payment status polling. payment_screen.dart and the promotion flow both ' +
      'poll every 5 seconds (12/min) while an STK prompt is outstanding, which ' +
      'can last two minutes. 40 burst / 30 per min supports two concurrent ' +
      'payment flows on one device without ever tripping.',
    rules: [
      {
        id: 'subject',
        algorithm: 'token-bucket',
        by: ['auth.uid', 'query.user_id', 'params.postId'],
        capacity: 40,
        refillTokens: 30,
        refillIntervalMs: MINUTE,
      },
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 600,
        refillTokens: 400,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  {
    name: 'payments:release',
    rationale:
      'B2C payout release. Keyed on the POST being paid out rather than on a ' +
      'caller, because the request body carries only post_id — and the resource ' +
      'is the right thing to protect: 5 release attempts per hour for one post ' +
      'is ample for a genuine retry after a Daraja timeout, and caps repeated ' +
      'attempts against the same escrow. The service is idempotent on ' +
      'transaction status (an already-released payout is a 409), so this is ' +
      'defence in depth over that guard, not a replacement for it.',
    rules: [
      {
        id: 'post',
        algorithm: 'sliding-window',
        by: ['body.post_id'],
        windowMs: HOUR,
        limit: 5,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 60 },
    ],
  },

  {
    name: 'payments:callback',
    rationale:
      'Daraja posts STK, B2C and status results here. DELIBERATELY THE LOOSEST ' +
      'POLICY IN THE FILE, and that is the considered choice: dropping a ' +
      'genuine callback is worse than absorbing a forged one. A rejected ' +
      'callback means a payment that never settles — money taken from a user ' +
      'with no job funded, resolvable only by manual reconciliation. Safaricom ' +
      'delivers from a small set of addresses shared across all merchants, so ' +
      'callbacks concentrate on few IPs and a tight limit would throttle real ' +
      'traffic. 1200 burst / 600 per min per IP stops a flood from exhausting ' +
      'the database connection pool while leaving genuine bursts untouched. ' +
      'NOTE: these endpoints are unauthenticated and this limit does NOT make ' +
      'forged callbacks safe — see the security report.',
    rules: [
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 1200,
        refillTokens: 600,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  {
    name: 'payments:smoke',
    rationale:
      'POST /mpesa/test-stk sends an STK prompt to an ARBITRARY phone number ' +
      'supplied in the body, with no authentication. It is a developer smoke ' +
      'test that is reachable in production, which makes it the single most ' +
      'abusable endpoint on this API: a harassment tool and a Daraja quota ' +
      'burner. 3 per hour per IP is all a smoke test ever needs. This limit ' +
      'contains the endpoint; it does not fix it — see the security report for ' +
      'the recommendation to gate it out of production entirely.',
    rules: [{ id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 3 }],
  },

  {
    name: 'promotions:manage',
    rationale:
      'Creating a promotion campaign and managing its lifecycle (pause, resume, ' +
      'cancel). A campaign is a considered purchase and its lifecycle is touched ' +
      'a handful of times over days — 20 an hour is far past any real merchant. ' +
      'The PAY call is NOT covered here: it pushes an STK prompt, so it carries ' +
      'payments:initiate like every other STK path.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid', 'body.user_id'],
        windowMs: HOUR,
        limit: 20,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 120 },
    ],
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // CREDENTIALS — where a limit is the ONLY thing standing between an
  // attacker and a guessable secret
  // ═══════════════════════════════════════════════════════════════════════════

  {
    name: 'otp:verify',
    rationale:
      'THE MOST IMPORTANT LIMIT IN THIS FILE. A payout OTP is 6 digits — one ' +
      'million combinations — valid for 5 minutes, and before this phase the ' +
      'verify endpoint had no limit of any kind. At even 200 requests a second ' +
      'the whole keyspace is exhaustible inside the validity window, and the ' +
      'prize is control of where a provider`s money is sent. ' +
      '5 attempts per 15 minutes per provider matches how many times a person ' +
      'mistypes a code they are reading off a screen. The IP rule (30/hour) is ' +
      'the one that stops the attack, because provider_id is supplied by the ' +
      'caller: without it an attacker would simply rotate the id. Together they ' +
      'cut the reachable keyspace to a few hundred guesses per hour per host — ' +
      'a ~0.03% chance of hitting a live code before it expires.',
    rules: [
      {
        id: 'provider',
        algorithm: 'sliding-window',
        by: ['body.provider_id'],
        windowMs: 15 * MINUTE,
        limit: 5,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 30 },
    ],
  },

  {
    name: 'otp:issue',
    rationale:
      'Registering a provider and changing a payout number both mint a new OTP ' +
      'and (once an SMS provider is wired in) send a text that costs money. ' +
      '3 per hour per provider covers "I did not get the code, resend"; the ' +
      '10/hour IP rule stops the endpoint being used as an SMS pump. Issuing ' +
      'also expires the previous code, so an unbounded version would let an ' +
      'attacker permanently deny a provider the ability to verify.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['body.provider_id', 'body.phone_login', 'body.phone_payout'],
        windowMs: HOUR,
        limit: 3,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 10 },
    ],
  },

  {
    name: 'payout:read',
    rationale:
      'Listing your own payout destinations. Cheap reads, but they reveal ' +
      'verification state — bounded so the endpoint cannot be used to probe ' +
      'the rate limiter itself.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid'],
        windowMs: HOUR,
        limit: 120,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 240 },
    ],
  },

  {
    name: 'payout:issue',
    rationale:
      'Minting a payout-destination OTP. Same economics as otp:issue — each ' +
      'issue will cost an SMS once Africa`s Talking is wired, and each reissue ' +
      'supersedes the previous code, so an unbounded version is a denial tool ' +
      'against a provider trying to verify. Keyed on the VERIFIED uid (these ' +
      'routes bind identity), so rotating a caller-supplied id does not reset ' +
      'the window. 5/hour covers add + a few resends on top of the 60s ' +
      'server-side cooldown.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid'],
        windowMs: HOUR,
        limit: 5,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 15 },
    ],
  },

  {
    name: 'payout:verify',
    rationale:
      'Guess attempts against a payout-destination OTP — the same keyspace ' +
      'arithmetic as otp:verify, with two additional walls that flow already ' +
      'lacks: the challenge row hard-stops at max_attempts=5 in the database, ' +
      'and the subject key is the verified uid rather than a caller-supplied ' +
      'provider_id. 5 per 15 minutes matches otp:verify — how often a person ' +
      'mistypes a code they are reading off a screen; the IP rule stays the ' +
      'backstop against distributed guessing.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid'],
        windowMs: 15 * MINUTE,
        limit: 5,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 30 },
    ],
  },

  {
    name: 'payout:manage',
    rationale:
      'Default selection and retirement. State changes with audit rows behind ' +
      'them — a runaway client flapping the default would flood the audit ' +
      'chain, and retirement is irreversible per row, so both deserve a ' +
      'ceiling a human would never hit.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid'],
        windowMs: HOUR,
        limit: 30,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 60 },
    ],
  },

  {
    name: 'admin:auth',
    rationale:
      'Unauthenticated admin surface: invite lookup, invite acceptance, and ' +
      'session restore. GET /admin/invite/:token is a token ORACLE — it answers ' +
      'whether a token is valid — so without a limit it is enumerable. Admin ' +
      'accounts resolve disputes and move money, so this is a high-value target ' +
      'with a small legitimate volume: an administrator accepts an invite once ' +
      'and restores a session a few times a day. 10 per minute AND 60 per hour ' +
      'per IP: the minute rule stops a fast script, the hour rule stops a slow ' +
      'one that stays under it.',
    rules: [
      { id: 'burst', algorithm: 'sliding-window', by: 'ip', windowMs: MINUTE, limit: 10 },
      { id: 'sustained', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 60 },
    ],
  },

  {
    name: 'admin:api',
    rationale:
      'Authenticated dashboard traffic. A human working through a dispute ' +
      'queue generates steady, bursty reads. Keyed on IP because the global ' +
      'guard runs BEFORE AdminAuthGuard — by design, so an invalid token is ' +
      'rejected cheaply — which means the admin identity is not yet resolved ' +
      'here. 240 burst / 120 per min suits a small internal team and would ' +
      'need revisiting if the dashboard is ever used from a shared office NAT ' +
      'by many admins at once.',
    rules: [
      {
        id: 'ip',
        algorithm: 'token-bucket',
        by: 'ip',
        capacity: 240,
        refillTokens: 120,
        refillIntervalMs: MINUTE,
      },
    ],
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // DISPUTES, UPLOADS AND BILLABLE THIRD PARTIES
  // ═══════════════════════════════════════════════════════════════════════════

  {
    name: 'disputes:create',
    rationale:
      'Raising a dispute freezes an escrow transaction and starts an SLA clock ' +
      'that pages a human. 5 per hour per person is far beyond honest use and ' +
      'stops the arbitration queue being flooded — a denial-of-service against ' +
      'the operations team rather than the server.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid', 'body.raised_by_user_id', 'body.user_id'],
        windowMs: HOUR,
        limit: 5,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 30 },
    ],
  },

  {
    name: 'disputes:participate',
    rationale:
      'Reading a case thread and replying to it. A dispute is an argument ' +
      'between two people, so a lively exchange is normal — 60 an hour allows a ' +
      'message a minute sustained, past which it is no longer a case ' +
      'submission.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid', 'body.user_id', 'query.user_id'],
        windowMs: HOUR,
        limit: 60,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 300 },
    ],
  },

  {
    name: 'uploads:sign',
    rationale:
      'Issues signed upload URLs into the private evidence bucket. Each URL is ' +
      'a WRITE CAPABILITY that outlives the request, so this is limited by what ' +
      'it hands out rather than by what it costs to serve — the cost of abuse ' +
      'lands later, as storage. A dispute might reasonably attach a dozen ' +
      'photos; 20 per hour covers that, and the request may ask for several ' +
      'URLs at once so each call costs 2 units, halving the effective ceiling ' +
      'for a caller that batches.',
    rules: [
      {
        id: 'subject',
        algorithm: 'sliding-window',
        by: ['auth.uid', 'body.user_id'],
        windowMs: HOUR,
        limit: 20,
        cost: 2,
      },
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 120, cost: 2 },
    ],
  },

  {
    name: 'routes:compute',
    rationale:
      'Google Routes proxy — the one endpoint that spends real money per call. ' +
      'Preserves EXACTLY the ceiling the in-process limiter enforced before this ' +
      'phase (40 per 10 minutes per IP): those numbers were already reasoned ' +
      'about in routes.service.ts against the client`s 45-90s refresh policy, ' +
      'and changing a limit at the same time as changing where it is enforced ' +
      'would confound two variables in any comparison. ' +
      'APPLIED INSIDE RoutesService, NOT BY THE GUARD — deliberately. The guard ' +
      'runs before the handler and would therefore count CACHE HITS, which cost ' +
      'nothing and can never be abuse. Calling the limiter after the cache lookup ' +
      'preserves the original semantics ("only calls that would reach Google are ' +
      'counted") while moving the state into Redis so the ceiling now holds ' +
      'across every replica instead of per process. The endpoint still carries ' +
      'the default policy from the guard as an outer backstop.',
    rules: [
      {
        id: 'ip',
        algorithm: 'sliding-window',
        by: 'ip',
        windowMs: 10 * MINUTE,
        limit: 40,
      },
    ],
  },

  // ═══════════════════════════════════════════════════════════════════════════
  // OPERATIONAL
  // ═══════════════════════════════════════════════════════════════════════════

  {
    name: 'health:deep',
    rationale:
      'The per-dependency health probes, which each perform real I/O. Loose ' +
      'enough for any monitoring cadence (60/min is one check a second) and ' +
      'tight enough that the endpoints cannot be used to amplify load onto ' +
      'Supabase. The plain /health liveness route is NOT limited at all — see ' +
      'the health controller for why.',
    rules: [
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: MINUTE, limit: 60 },
    ],
  },

  {
    name: 'dev:harness',
    rationale:
      'The /dev/* test harness and the M-Pesa dev helpers. Every one already ' +
      'returns 403 in production, so this is depth rather than the control — it ' +
      'bounds the damage if one is ever added without that guard.',
    rules: [
      { id: 'ip', algorithm: 'sliding-window', by: 'ip', windowMs: HOUR, limit: 30 },
    ],
  },
] as const;

/** Name → policy, built once at module load. */
export const POLICY_BY_NAME: ReadonlyMap<string, RateLimitPolicy> = new Map(
  RATE_LIMIT_POLICIES.map((policy) => [policy.name, policy]),
);

/**
 * Fail fast on a catalogue mistake.
 *
 * These are the errors that would otherwise surface as a silently missing or
 * permanently-denying limit in production, which is the hardest kind of bug to
 * notice: nothing breaks, protection is just absent. Called at module
 * construction so a typo cannot survive a single boot.
 */
export function validatePolicyCatalogue(
  policies: readonly RateLimitPolicy[] = RATE_LIMIT_POLICIES,
): void {
  const names = new Set<string>();

  for (const policy of policies) {
    if (names.has(policy.name)) {
      throw new Error(`[RateLimit] Duplicate policy name: "${policy.name}"`);
    }
    names.add(policy.name);

    if (policy.rules.length === 0) {
      throw new Error(`[RateLimit] Policy "${policy.name}" has no rules — it would allow everything.`);
    }

    const ruleIds = new Set<string>();
    for (const rule of policy.rules) {
      if (ruleIds.has(rule.id)) {
        throw new Error(
          `[RateLimit] Policy "${policy.name}" has duplicate rule id "${rule.id}" — ` +
            `both rules would share a Redis key and consume each other's budget.`,
        );
      }
      ruleIds.add(rule.id);

      const cost = rule.cost ?? 1;
      if (cost < 1) {
        throw new Error(`[RateLimit] ${policy.name}.${rule.id}: cost must be >= 1.`);
      }

      if (rule.algorithm === 'sliding-window') {
        if (rule.limit < 1 || rule.windowMs < 1) {
          throw new Error(`[RateLimit] ${policy.name}.${rule.id}: limit and windowMs must be >= 1.`);
        }
        if (cost > rule.limit) {
          throw new Error(
            `[RateLimit] ${policy.name}.${rule.id}: cost ${cost} exceeds limit ${rule.limit} — ` +
              `every request would be denied.`,
          );
        }
      } else {
        if (rule.capacity < 1 || rule.refillTokens < 1 || rule.refillIntervalMs < 1) {
          throw new Error(
            `[RateLimit] ${policy.name}.${rule.id}: capacity, refillTokens and refillIntervalMs must be >= 1.`,
          );
        }
        if (cost > rule.capacity) {
          throw new Error(
            `[RateLimit] ${policy.name}.${rule.id}: cost ${cost} exceeds capacity ${rule.capacity} — ` +
              `every request would be denied.`,
          );
        }
      }

      if (Array.isArray(rule.by)) {
        if (rule.by.length === 0) {
          throw new Error(`[RateLimit] ${policy.name}.${rule.id}: subject source list is empty.`);
        }
        for (const path of rule.by) {
          if (!/^(auth|body|query|params)\.[A-Za-z0-9_]+$/.test(path)) {
            throw new Error(
              `[RateLimit] ${policy.name}.${rule.id}: unsupported subject path "${path}". ` +
                `Expected auth.<field>, body.<field>, query.<field> or params.<field>.`,
            );
          }
        }
      }
    }
  }

  if (!names.has(DEFAULT_POLICY_NAME)) {
    throw new Error(
      `[RateLimit] The catalogue must define a "${DEFAULT_POLICY_NAME}" policy — ` +
        `it is what protects routes that declare none.`,
    );
  }
}
