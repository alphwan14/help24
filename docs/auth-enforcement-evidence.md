# Authentication Enforcement — Evidence and Rollout Recommendation

Status: **investigation only. No production change made, no environment variable
touched.** Every probe below was an unauthenticated `GET` against production.

---

## 0. The headline

While gathering evidence I found that the unenforced state is not merely a
missing safeguard — it is a **live, unauthenticated data exposure**, reachable
in two steps with no credentials at any point:

```
1.  GET /feed                              ← @Public by design (anonymous browsing)
    → returns author_user_id for every post

2.  GET /promotions/campaigns?user_id=<harvested uid>   → HTTP 200, 3 records
    GET /promotions/payments?user_id=<harvested uid>    → HTTP 200, 1 record
    ← both are @Auth-declared, and neither asks for a token
```

Control: the same routes with a non-existent uid return `[]` (2 bytes), which
confirms the data returned for a real uid is that user's actual campaign and
payment history, not a generic response.

The UIDs are not secret and were never meant to be — `author_user_id` is part of
the public feed payload, which is correct for a browsable marketplace. The defect
is entirely on the other side: routes that declare `@Auth` are not enforcing it.

This raises the priority of the decision. It is no longer "the authorization
model is advisory"; it is "a stranger can read a user's spending history".

---

## 1. What `authWouldDeny` actually measures, and why I could not read it

`authWouldDeny` is annotated onto the request context and emitted in the access
log (`auth.guard.ts:160`, `:186`). Those logs live in Render's log stream, which
I have no access to from here. **I cannot report the counter.**

I do not think that is a real loss, and here is why: the counter tells you *how
many* requests would be denied. It does not tell you *which flows* or *whether
the denial matters*. I derived those directly from the shipped client instead,
which answers the question the counter is a proxy for. Where I could not
establish something from the code, I say so rather than assume.

A second finding makes the counter less decisive than it first appears:

> **In `monitor`, identity conflicts are already CORRECTED, not merely observed.**
> `auth.guard.ts:184` calls `resolveConflictsToVerified` — the request proceeds
> as the person the token proves, not the person the body claimed.

So `authWouldDeny` conflates two very different populations:

| Recorded as `authWouldDeny` | Under `monitor` today | Under `enforce` |
|---|---|---|
| `identity_conflict` — a token is present but the body claims someone else | **Already corrected.** The caller cannot act as another user | 403 |
| `absent` / verification failure — no usable token at all | **Allowed through on its asserted values** | 401 |

Only the second row is a behaviour change worth fearing, and only the second row
is the exposure in §0. A high counter driven by the first row would be
misleading — that protection is already switched on.

---

## 2. Every `@Auth` GET route, probed unauthenticated against production

`404` here means the request passed authentication entirely and reached the
service, which then found no such record. It is a *pass*, not a rejection.

| Route | Declared | Response with no token |
|---|---|---|
| `GET /jobs/:postId/status` | `@Auth()` | **200** |
| `GET /jobs/:postId/lifecycle` | `@Auth('query.user_id')` | 404 (reached handler) |
| `GET /mpesa/status/:postId` | `@Auth()` | 404 (reached handler) |
| `GET /reviews/eligibility/:postId` | `@Auth('query.user_id')` | **200** |
| `GET /promotions/campaigns` | `@Auth('query.user_id')` | **200 — leaks real data** |
| `GET /promotions/payments` | `@Auth('query.user_id')` | **200 — leaks real data** |
| `GET /promotions/campaigns/:id` | `@Auth('query.user_id')` | 404 (reached handler) |
| `GET /promotions/campaigns/:id/payment-status` | `@Auth('query.user_id')` | 404 (reached handler) |
| `GET /promotions/campaigns/:id/analytics` | `@Auth('query.user_id')` | 404 (reached handler) |
| `GET /disputes/:id/thread` | `@Auth('query.user_id')` | 404 (reached handler) |

I deliberately did **not** probe the `@Auth` POST routes (initiate payment,
approve, mark-complete, select-provider, archive, dispute create, review submit).
Those mutate state, and confirming they are unenforced is not worth writing to
production. They share the same guard and the same configuration, so the same
conclusion applies to them by construction.

---

## 3. Which real client flows would fail under `enforce`

Derived by tracing every backend call in `mobile-app/lib` to its call site and
checking whether that site can execute without a signed-in user.

### 3.1 Would break — one flow, silently, cosmetically

| Flow | Why it can fire signed-out | Consequence under `enforce` |
|---|---|---|
| `post_detail_screen.dart:130-134` `_refreshJobStatus()` → `GET /jobs/:postId/status` | Gated only on `post.type == request && _selectedProviderId != null` (`:108-113`). **Not gated on sign-in.** Post detail is reachable from the browsable feed | `jobs_service.dart:167-184` swallows every non-200 and returns `null`, so `_jobStatus` stays null and the job-completion section simply does not render. **No error, no crash, no user-visible message** |

For a signed-out viewer, not seeing another person's job-completion state is
arguably the correct behaviour — enforcement fixes a small information leak here
rather than breaking a feature.

### 3.2 Verified safe — already gated

| Flow | Why it cannot fire signed-out |
|---|---|
| `POST /feed/interactions` (telemetry from the browsable Discover feed — the most likely candidate) | `interaction_tracker.dart:150` and `:188` both `return` when `_userId.isEmpty`. Nothing is queued and nothing is flushed for an anonymous browser |
| `GET /mpesa/status/:postId` and `GET /jobs/:id/status` from `JobStatusCard` | The widget is mounted only inside chat (`chat_ui.dart:213`), which requires sign-in |
| Reviews, disputes, promotions management, payments, job lifecycle | All reached from screens behind `AuthGuard.requireAuth` |
| `/feed`, `/reputation`, `/reviews/provider/:id`, `/promotions/packages`, `/promotions/slots`, `/promotions/events` | `@Public` by declaration — unaffected by enforcement |

### 3.3 Identity conflicts — expected to be zero

The app derives the `user_id` it sends from `AuthProvider.currentUserId`, which
is the Firebase UID of the same session that mints the ID token. The two cannot
diverge for a correctly functioning client. And because `monitor` already
*corrects* conflicts rather than observing them, any that do occur are already
being handled today without a rejection.

### 3.4 What I could not establish

- The actual `authWouldDeny` counts, per §1.
- Whether any client build older than the current one calls these routes
  differently. The `@Auth` mechanism and identity binding shipped together, so a
  client predating them sends the same body fields; it simply never attached a
  token. **Such a client would 401 under enforcement** on every route in §2. If
  meaningful traffic still comes from pre-token builds, the §4 staged rollout
  handles it; a blanket flip would not.

---

## 4. Recommended rollout

The mechanism for exactly this already exists and is unused:
`AUTH_ENFORCE_ONLY` (`auth.config.ts:92-120`) narrows enforcement to a list of
path prefixes or `METHOD /path` entries, and the boot fails if it is set without
`AUTH_ENFORCEMENT=enforce` (`:41-48`). Its own comment describes this use case:
"money endpoints are worth enforcing the day the new client reaches most devices;
the Discover feed can wait for the long tail of upgrades."

**Stage 1 — close the exposure now, narrowly.**

```
AUTH_ENFORCEMENT=enforce
AUTH_ENFORCE_ONLY=/promotions
```

Rationale: `/promotions/campaigns` and `/promotions/payments` are the two routes
proven to leak real user data, and every promotions surface in the app sits
behind a sign-in gate — so the blast radius on legitimate users is nil. The
public promotion routes (`/promotions/packages`, `/slots`, `/events`) are
`@Public` and are unaffected: `shouldEnforce` gates enforcement, and `@Public`
routes never reach the protected branch at all.

**Correction to an earlier draft of this document.** I previously wrote that the
prefix also matches `/admin/promotions`. It does not. `shouldEnforce`
(`auth.config.ts:118`) uses `path.toUpperCase().startsWith(entry)`, which
anchors at position 0, so `/admin/promotions/...` never matches `/promotions`.
The conclusion is unchanged — admin routes are unaffected either way, because
they carry `scheme: 'admin'` and the guard returns immediately for them
(`auth.guard.ts:100-104`), leaving `AdminAuthGuard` in charge — but the stated
reason was wrong.

Re-verified for this rollout: `@Public` routes are **never rejected** under
enforcement (`handlePublic`, `auth.guard.ts:118-123`), so `/promotions/packages`,
`/promotions/slots` and `/promotions/events` keep serving anonymous callers.

**Stage 2 — money and workflow.** Add `/mpesa`, `/jobs`, `/disputes`,
`/reviews` once Stage 1 has been live for a few days with no support signal.
Expect one behaviour change, the silent one in §3.1.

**Stage 3 — everything.** Clear `AUTH_ENFORCE_ONLY`, leaving
`AUTH_ENFORCEMENT=enforce`.

**Before Stage 1, do two things I could not do from here:**
1. Read `authWouldDeny` in the Render logs and check the split between
   `identity_conflict` (harmless — already corrected) and `absent` (the real
   population). A large `absent` count on `/promotions` would mean live clients
   I have not accounted for.
2. Confirm the route audit is clean at boot. It already is — the boot check I ran
   under `AUTH_ENFORCEMENT=enforce` reported 108 routes, `undeclared=0`, "Every
   route declares a scheme and every admin route is guarded". **Enforcement will
   not fail the boot.**

**Rollback** is the same env change in reverse, no redeploy of code
(`auth.types.ts:13-16`). Nothing about this is one-way.

---

## 5. Recommendation

**Do Stage 1.** The exposure is live, unauthenticated, and reachable in two
steps; the routes it closes are behind a sign-in gate in every shipped client
path I traced; the boot audit is clean; and rollback is an env var.

I have not made the change. It is yours to make, and worth pairing with a look at
the log counter first.

**Separately, and regardless of the enforcement decision:** consider whether
`GET /promotions/campaigns` and `/promotions/payments` should also be scoped
server-side to the authenticated user rather than trusting `query.user_id`.
Identity binding does exactly that once enforced — but a route whose entire
authorization is "the caller told us who they are" is worth a second look even
after the binding is live.
