# Admin dashboard performance

Status as of **2026-11-06**. The record of the admin console
(admin.help24.co.ke) speed work: what was measured, what shipped, and what
is still open. Read "Where we stopped" first.

## Where we stopped

All seven planned stages shipped on 2026-10-26. Stages 1 and 2 were checked
against the owner's own console timings from Nairobi; stages 3–7 were
checked locally and in logs, never re-measured from a browser. On 2026-10-29
one decision was reversed (see Stage 3).

**Open, in the order I would take them:**

1. **Re-measure.** Nothing has been timed from the owner's browser since
   2026-10-26, and f5a7a47 (2026-10-29) made 13 pages render per request,
   which costs server time on every view. Use the snippet in
   [Measuring](#measuring), visit every section twice, and compare against
   the baselines below. Use the Server-Timing header
   (`auth`, `gate`, `mw`) to split middleware time from page time.
2. **Overview takes ~3 s to settle** with no server request in the samples:
   charts drawing and animating in the browser. Not yet looked at. Likely fix:
   no entry animation, and the charts rendered after the figures.
3. **Vercel Fluid Compute** — whether it is on was never read (the CLI does
   not show it). Owner to check in Vercel → Project → Settings → Functions.
   It reduces cold starts, which the logs suggest are part of the 260–450 ms
   gap between middleware and the page function.
4. **Render backend is on the free plan.** It sleeps when idle and is kept
   awake only by an UptimeRobot `HEAD /health` every 5 minutes. If that
   monitor stops, the first console click after a quiet spell waits for a
   cold start (tens of seconds), and the auto-approval sweep and event retry
   loop stop too. A paid instance removes the dependency.

Not worth doing (measured, see Diagnosis): moving off Supabase, moving
regions, adding Redis, rewriting the dashboard in another framework.

## Diagnosis (2026-10-25/26)

Measured, not assumed. Regions come from Supabase's edge logs (caller colo
and ASN), not from configuration:

| Piece | Where it runs |
|---|---|
| Supabase (Postgres + PostgREST + Auth) | eu-west-1, **Dublin** |
| Vercel page functions | **fra1** Frankfurt |
| Vercel middleware | **lhr1** London (not fra1) |
| Render backend (`help24-backend`) | **Frankfurt**, free plan, 1 instance |
| Browser edge from Nairobi | cpt1 Cape Town |

**Geography is not the cause.** Each navigation makes one Africa↔Europe hop.
Database time per query was 9–66 ms and the data is tiny. Moving Supabase to
a nearer region would save about 20 ms per query. The database itself adds
almost nothing; the round trip is everything, so do not migrate off Supabase
for speed.

**Where the time went:**

- Most `/dashboard` sections had no `loading.tsx`, so a click left the old
  page on screen until the server finished: it looked dead for 0.8–1.9 s.
- Middleware made **three serial Supabase calls** (session → identity link →
  role) on every request, including every sidebar-link prefetch (bursts of
  4–5 per page view).
- Backend-driven pages awaited `getCurrentAdmin()` and only then started
  their data request: two round trips in series, four on a dispute's page.
- 260–450 ms between middleware and the page function in the logs: the
  handoff, likely plus cold starts.
- Login did push + refresh + redirect: three round trips to land.
- **Correctness bug:** about 12 data pages were built as static at deploy time
  and never re-queried, so they showed deploy-day numbers.

**Baselines (owner's console, Nairobi):**

| Measure | Before (2026-10-25) | After Stage 1 (2026-10-26) |
|---|---|---|
| Click → something on screen | p50 ≈ 1,100 ms (802–1,869, n=9) | **p50 20 ms, worst 25 ms (n=17)** |
| Click → page usable | p50 ≈ 1,100 ms | p50 1,299 ms (n=7) |
| Server wait (RSC request) | p50 ≈ 736 ms (n=14) | p50 835 ms (n=7; same work, different hour) |

## What shipped

Each stage was its own commit and deploy, with a pass condition.

| Stage | Commit | What changed | Result |
|---|---|---|---|
| 1. Loading screens | `c821da1` | A `loading.tsx` per section (one per section, because a boundary only fires for the segment directly beneath it). A guard test fails if a new section lacks one. | **Passed**: feedback 13–25 ms on every route. |
| 2. Data alongside the access check | `a36ca19` | `startEarly()`: pages start their backend reads together with `getCurrentAdmin()` instead of after it. Denial still runs first; every early read is `support_agent`-level. | **Passed** in the backend access log: check and data start within 1–15 ms of each other on all 13 page loads. |
| 3. Frozen pages | `2755d8b` → **superseded by `f5a7a47`** | First fix: `revalidate = 60` on the 12 frozen pages. On 2026-10-29 the Jobs page showed 1 job while 2 were live: Next rebuilds only when asked and answers that request with the old render, so on a console opened a few times a day the first view is nearly always stale. The 12 pages and Overview now render per request (`force-dynamic`). `route-freshness.test.mjs` fails if a data page answers with a cached render. | Fresh data on every view; costs server time per view (re-measure, item 1). |
| (found by 3) | `9836688` | Geography and Heatmap queried a `users.location` column that doesn't exist and showed "0 users" per city. The figures are gone; a failed read says so. | Fixed. |
| Filters | `ce4ba23` | A query-string change never fires `loading.tsx`, so status filters looked dead for 1.0–3.2 s. `FilterLink` highlights at once and dims the list until results arrive. Requests' plain `<a>` filters (full page reloads) replaced. | Fixed. |
| 4. One-trip admin gate | `d5da233` | Middleware asks for the identity link and the role in one query: `user_auth_identities?select=help24_user_id,users(role)`. Same refusals, fails closed. | Verified against production PostgREST before shipping. |
| 5. One-step sign-in | `58d6cd6` | Every landing goes straight to `DASHBOARD_HOME` (`/dashboard/overview`) with one `replace`. AdminShell's refresh after restoring access is **deliberately kept**: Escrow and other token-reading pages depend on it on first load. | Shipped. |
| 6. Instant revisits | `b1000e7` | `experimental.staleTimes.dynamic = 30`: revisiting a page within 30 s comes from the tab's memory. Every mutation revalidates; the Users role toggle was the one that didn't, and now does. | Shipped. Worst case: a page up to 30 s old after **another** admin changed it. |
| 7. Instrumentation | `3c484a4` | Middleware sends `Server-Timing` (`auth`, `gate`, `mw`). `adminRequest` logs one `[api]` line per backend call (method, path, status, ms, `x-request-id`), which the backend adopts, so both sides' lines share an id. Never a token or body. | Shipped. |

**Related, since then (2026-10-30):** the console used to lose its backend key
when a second device signed in, which showed up as errors and reload loops
rather than slowness. Fixed by one key per sign-in (migration 133, `1a02de3`)
and server actions that renew a refused key once (`9d75f20`). See
`docs/runbooks/admin-onboarding-and-identity-linking.md` and the
`admin_sessions` comment in migration 133.

## Measuring

The snippet that produced the baselines above (owner’s console, 2026-10-25/26).
Paste it in the browser console on admin.help24.co.ke, click through the
sections (each twice), then run `copy(JSON.stringify(window.__navLog))` and
paste the result. Per navigation it records `feedback_ms` (click → first
change on screen), `usable_ms` (click → the page stops changing),
`server_wait_ms` and `rsc_total_ms` (the RSC request). It times only links
under `/dashboard`; filter changes that only alter the query string are not
captured.

```js
(() => { performance.setResourceTimingBufferSize(5000); const log = (window.__navLog = []); let nav = null;
  const rsc = n => performance.getEntriesByType("resource").filter(x => x.name.includes("_rsc=") && x.startTime >= n.t0 - 5).pop();
  const done = () => { const n = nav, r = rsc(n), age = performance.now() - n.t0;
    if (age < 15000 && ((!r && age < 3000) || (r && n.last < r.responseEnd))) { n.timer = setTimeout(done, 400); return; }
    nav = null; const row = { route: n.from + " → " + n.href, feedback_ms: Math.round(n.first - n.t0), usable_ms: Math.round(n.last - n.t0),
      server_wait_ms: r ? Math.round(r.responseStart - r.requestStart) : null, rsc_total_ms: r ? Math.round(r.responseEnd - r.startTime) : null };
    log.push(row); console.table([row]); };
  document.addEventListener("click", e => { const a = e.target.closest('a[href^="/dashboard"]'); if (!a || a.getAttribute("href") === location.pathname) return;
    nav = { t0: performance.now(), from: location.pathname, href: a.getAttribute("href"), first: 0, last: 0, timer: 0 }; }, true);
  new MutationObserver(() => { if (!nav) return; const t = performance.now(); nav.first ||= t; nav.last = t;
    clearTimeout(nav.timer); nav.timer = setTimeout(done, 800); }).observe(document.querySelector("main"), { childList: true, subtree: true, characterData: true });
})();
```

Server side: Vercel → Logs filtered on `[Admin Check]` (gate durations) and
`[api]` (each backend call); match an `[api]` line to the backend's Render
access-log line by its request id.

## Rules that came out of this

- A data page renders per request (`force-dynamic`). Never `revalidate`
  for admin data: an infrequently opened console makes "at most a minute
  old" mean "stale on first view". The freshness test enforces it.
- Every dashboard section has a `loading.tsx` (guard test).
- Start independent reads together (`startEarly`), never one after another.
- The admin gate is one query; don't add a lookup to middleware.
- A query-string filter needs `FilterLink`/`FilterResults`, not a plain link.
