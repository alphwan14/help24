# Discover feed load test

Proves that Discover reaches every eligible post (not just the first page), and
measures what that costs on the live stack. Built after the 2026-10-26 report
that Discover stopped at 20 posts. See `mobile-app/lib/services/feed_pager.dart`.

| Script | Writes? | What it does |
|---|---|---|
| `walk.mjs [--scope all\|requests\|offers\|jobs]` | no | Walks the feed exactly as the app does (ranked `/feed` pages, then the keyset tail with the app's publishable key) and compares the count with the table. Exit 0 only on an exact, duplicate-free match. |
| `bench.mjs [--readers 10] [--rounds 3]` | no | Many `walk`s at once. Reports latency percentiles per step, throttling, and incomplete walks. |
| `seed.mjs --run <id> --count <n>` | **production** | Synthetic OFFER listings owned by one synthetic author `loadtest-feed-<id>`. Refuses to run without `--i-have-approval-to-write-production`. |
| `cleanup.mjs --run <id>` | **production** | Deletes that author's posts in batches of 500, then the author, and verifies zero remain. Same flag. |

Writes need explicit approval for each run (see the production-write rule).
Credentials come from `backend/.env`. No values are printed.

Typical run: `walk` (baseline) → `seed` → `walk` per scope → `bench` → `cleanup` → `walk` (baseline again).
