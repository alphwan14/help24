/**
 * Lua scripts executed inside Redis.
 *
 * WHY LUA AND NOT A SEQUENCE OF COMMANDS
 * --------------------------------------
 * "Read the counter, decide, write the counter" is three round trips, and
 * between any two of them another replica can do the same thing. Two requests
 * that each read `4/5` both conclude they are allowed and the limit becomes 6.
 * That race is not theoretical — it is exactly what happens the moment a user
 * double-taps a button, which is the single most common way a real person
 * generates concurrent requests.
 *
 * Redis executes a script atomically: it is single-threaded per script, and no
 * other command from any connection can interleave. Check-and-consume becomes
 * one indivisible operation, and the limit is a limit no matter how many
 * backend instances are running. This is the property that makes the whole
 * rate-limiting layer correct under horizontal scaling.
 *
 * WHY THE CLOCK COMES FROM REDIS, NOT FROM NODE
 * ---------------------------------------------
 * Every script below reads `redis.call('TIME')` instead of accepting a
 * timestamp from the caller. With one backend instance those are equivalent.
 * With three, they are not: container clocks drift, and a replica running two
 * seconds fast would evict another replica's still-valid entries from a
 * sliding window, silently handing out extra budget. One clock — the Redis
 * server's — removes the entire class of problem.
 *
 * (`TIME` is a non-deterministic command. Redis >= 5 replicates scripts by
 * their effects rather than by re-running them, so this is safe. The service
 * logs the server version at connect; anything older than 5 must not be used.)
 *
 * RETURN CONTRACT (shared by both scripts)
 * ----------------------------------------
 *   [ allowed, limit, remaining, retryAfterMs ]
 *     allowed      1 = consumed, 0 = denied (nothing was consumed)
 *     limit        the ceiling, echoed back so headers need no second source
 *     remaining    budget left AFTER this call (0 when denied)
 *     retryAfterMs milliseconds until the next unit frees up (0 when allowed)
 *
 * Redis truncates Lua numbers to integers on return, so every value is
 * rounded here rather than left to chance.
 */

/**
 * SLIDING WINDOW LOG — exact, O(n) memory in requests per window.
 *
 * Every accepted request leaves a timestamped member in a sorted set; expired
 * members are trimmed on each call. The count is therefore exact and the
 * window truly slides: there is no boundary at which the budget resets.
 *
 * WHY EXACTNESS IS WORTH THE MEMORY HERE
 * A fixed window allows double the limit across its boundary — 5 requests at
 * 11:59:59 and 5 more at 12:00:00 is 10 in one second. For "5 OTP attempts per
 * 15 minutes" that is the difference between a limit and a suggestion. This
 * algorithm is reserved for low-volume, high-value endpoints (OTP, payment
 * initiation, payout release) where n per key is single digits and the memory
 * cost is irrelevant.
 *
 * The key always carries a TTL of one window, so an abandoned key evicts
 * itself. PEXPIRE is re-applied on the denied path too — otherwise a key that
 * only ever gets rejections would keep its old TTL and could outlive its data.
 */
export const SLIDING_WINDOW_LUA = `
-- Opt into effects replication before the first write. On Redis 5 and 6 a
-- script that calls a non-deterministic command (TIME, below) and then WRITES
-- is rejected outright unless this has been called. Redis 7 replicates by
-- effects unconditionally and keeps this as a no-op, and the existence check
-- means the line is still safe if a future version removes it entirely. One
-- line that makes these scripts portable across every server they might meet.
if redis.replicate_commands then redis.replicate_commands() end

local key      = KEYS[1]
local window   = tonumber(ARGV[1])
local limit    = tonumber(ARGV[2])
local cost     = tonumber(ARGV[3])
local seed     = ARGV[4]

local time     = redis.call('TIME')
local now_ms   = (tonumber(time[1]) * 1000) + math.floor(tonumber(time[2]) / 1000)
local cutoff   = now_ms - window

redis.call('ZREMRANGEBYSCORE', key, '-inf', cutoff)
local used = redis.call('ZCARD', key)

if (used + cost) > limit then
  -- Denied. The next unit frees when the OLDEST surviving entry leaves the
  -- window, which is what the caller needs for an honest Retry-After.
  local oldest = redis.call('ZRANGE', key, 0, 0, 'WITHSCORES')
  local retry_ms = window
  if oldest[2] then
    retry_ms = (tonumber(oldest[2]) + window) - now_ms
    if retry_ms < 1 then retry_ms = 1 end
  end
  redis.call('PEXPIRE', key, window)
  return {0, limit, 0, math.ceil(retry_ms)}
end

-- A cost of N occupies N slots. Members must be unique or ZADD would overwrite
-- rather than accumulate, so each carries the caller's per-request seed.
for i = 1, cost do
  redis.call('ZADD', key, now_ms, seed .. ':' .. i)
end
redis.call('PEXPIRE', key, window)

return {1, limit, limit - (used + cost), 0}
`;

/**
 * TOKEN BUCKET — O(1) memory, burst-tolerant.
 *
 * A bucket holds at most `capacity` tokens and regains `refillTokens` every
 * `refillIntervalMs`. A request spends `cost` tokens or is denied.
 *
 * WHY THIS SHAPE FITS A MOBILE CLIENT
 * Opening a screen in the Help24 app fires several requests at once — feed,
 * promotion slots, viewer context. A flat "30 per minute" would reject the
 * legitimate burst that every cold start produces, while still permitting a
 * scripted attacker to sit exactly at the line forever. A bucket inverts that:
 * it absorbs the burst (capacity) and constrains the sustained rate (refill),
 * which is precisely the distinction between a person using the app and a
 * program abusing it.
 *
 * Only two fields are stored regardless of traffic, so this is the algorithm
 * for high-volume endpoints where a per-request log would be wasteful.
 *
 * Refill is computed lazily from elapsed time rather than by a background
 * job — there is nothing to schedule, and a bucket nobody touches costs
 * nothing until its TTL expires.
 */
export const TOKEN_BUCKET_LUA = `
-- See the note in SLIDING_WINDOW_LUA: required on Redis 5/6, no-op on 7+.
if redis.replicate_commands then redis.replicate_commands() end

local key       = KEYS[1]
local capacity  = tonumber(ARGV[1])
local refill    = tonumber(ARGV[2])
local interval  = tonumber(ARGV[3])
local cost      = tonumber(ARGV[4])

local time      = redis.call('TIME')
local now_ms    = (tonumber(time[1]) * 1000) + math.floor(tonumber(time[2]) / 1000)

local state  = redis.call('HMGET', key, 'tokens', 'ts')
local tokens = tonumber(state[1])
local ts     = tonumber(state[2])

if tokens == nil or ts == nil then
  -- First contact: a new caller starts with a full bucket, so the very first
  -- request is never penalised for the absence of history.
  tokens = capacity
  ts     = now_ms
end

-- Guard against a negative delta. Redis TIME is monotonic in practice, but a
-- clock stepped backwards by NTP would otherwise DRAIN the bucket.
local elapsed = now_ms - ts
if elapsed < 0 then elapsed = 0 end

tokens = math.min(capacity, tokens + ((elapsed / interval) * refill))

local allowed  = 0
local retry_ms = 0

if tokens >= cost then
  -- Consumed: persist the new balance and reset the clock to now.
  tokens  = tokens - cost
  allowed = 1
  redis.call('HSET', key, 'tokens', tokens, 'ts', now_ms)
else
  retry_ms = math.ceil(((cost - tokens) / refill) * interval)
  -- DENIED: state is deliberately NOT rewritten.
  --
  -- Persisting the fractional balance on every rejection would re-round it
  -- each time, and the error accumulates: a caller hammering a drained bucket
  -- banks slightly less than the configured rate on every attempt and ends up
  -- permanently below it. Leaving (tokens, ts) alone means the balance is
  -- always ONE multiplication away from a stable anchor, which is exact.
  --
  -- The TTL is still refreshed below, and that is the part that matters for
  -- enforcement — see the PEXPIRE note.
end

-- PEXPIRE runs on BOTH paths, and on the denied path it is what keeps the
-- limit enforceable. Without it, a caller hammering a drained bucket would let
-- the key expire mid-attack; the next request would find no state, start from
-- a FULL bucket, and the limit would be completely bypassed by anyone who
-- simply does not back off.
--
-- The value: time to refill from empty to full, plus one interval of slack.
-- Once a bucket has been idle that long it is indistinguishable from a fresh
-- one, so keeping it would only consume memory.
redis.call('PEXPIRE', key, math.ceil((capacity / refill) * interval) + interval)

return {allowed, capacity, math.floor(tokens), retry_ms}
`;

/**
 * Names registered on the ioredis client via `defineCommand`, which handles
 * the EVALSHA → NOSCRIPT → EVAL dance internally: scripts are sent once per
 * connection and referenced by hash thereafter, and a Redis restart that
 * clears the script cache recovers automatically.
 */
export const SCRIPT_NAMES = {
  slidingWindow: 'h24SlidingWindow',
  tokenBucket: 'h24TokenBucket',
} as const;
