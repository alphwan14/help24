# Direct Service Requests (WhatsApp → assisted matching) — product assessment

Status: **BUILD LATER — deferred, gated on provider supply.**
Assessed: 2026-09-12, against the live production database and the live
`api.help24.co.ke` ranking service. Not against the repository.

---

## 1. The proposal

Help24 gets a Business WhatsApp number. Someone messages "I need a plumber in
Nyali, KSh 2,000, today". An operator captures the request in the admin
dashboard, presses **Find Providers**, the existing recommendation engine
returns ranked providers, and the operator sends options back over WhatsApp.
The interaction doubles as an app-acquisition funnel.

The idea is sound. It is deferred for one reason only: **there is nothing to
match against.**

## 2. Why not now — live evidence

Every number below is from the production database on 2026-09-12.

| Measure | Live value |
|---|---|
| Registered users, all time | 16 |
| Users with any profession set | 4 (12 of 16 are the empty string) |
| Verified providers | **0** |
| Providers with an availability window set | **0** |
| Providers with any `user_skills` row | **0** |
| Offer posts (the entire sellable supply) | **9**, of which 8 belong to one account |
| Distinct offer authors | **2** (one is the founder's own account) |
| Newest offer | 2026-08-02 |
| Posts created in the last 30 days | 2 |
| Users joined in the last 30 days | 1 |

The supply is two people, one of whom is us.

### 2.1 The proposed feature, run against production

Both queries were issued to the live ranking service exactly as a "Find
Providers" button would issue them.

```
GET /feed?scope=offers&categories=Electrical&lat=-4.0435&lng=39.6996&max_price=3000&urgency=urgent
  -> candidate_count: 0     items: []

GET /feed?scope=offers&categories=Plumbing&lat=-4.0435&lng=39.6996&max_price=2000&urgency=urgent
  -> candidate_count: 0     items: []
```

The operator presses the button and gets an empty screen. There is no
electrician offer anywhere in the country, and the single plumbing offer is in
Nakuru, posted 2026-02-20, roughly 500 km from Nyali.

### 2.2 The engine itself is healthy — this is not an engine problem

The same service, unfiltered, answers correctly and fast:

```
GET /feed?scope=offers&radius_km=2000   -> candidate_count: 8, took_ms: 130
GET /feed?radius_km=2000                -> candidate_count: 26
```

Ranking works. Retrieval works. Anonymous (non-personalised) mode works, which
is precisely the mode an operator would use. Building the operator UI would
add no capability the engine lacks; it would surface an empty marketplace
through a second door.

## 3. The deeper structural finding

Help24's supply discovery is **pull-based**: a client posts a request, and
providers browse and apply. The recommendation engine is built for exactly that
direction — the *viewer is a provider*, the *candidates are posts*. See
`backend/src/feed/ranking/signals/profession.signal.ts`, which scores the
**viewer's** profession against the **candidate post's** category.

The direct-request workflow needs the inverse: given a request, rank *people*.
Help24 has no provider directory, no provider-search endpoint, and no provider
retrieval function. `backend/src/providers/providers.controller.ts` exposes only
`register`, `verify-payout` and `change-payout`.

So there are two honest options, and only one of them is permitted:

1. **Search offer posts** (`scope=offers`) as a proxy for providers. Reuses the
   engine completely, needs zero backend change — but only finds the minority of
   providers who bothered to post an advert. Today that is 2 people.
2. **Rank providers directly.** This is a second matching algorithm, which the
   brief explicitly forbids and the backend freeze forbids.

Option 1 is the right MVP when supply exists. Option 2 is not on the table.

## 4. What would flip this to BUILD

Revisit when **all** of the following hold:

- ≥ 50 providers with a profession set, in one city (Mombasa is the natural
  first market — 60% of existing posts are already Mombasa-area).
- ≥ 30 open offer posts, from ≥ 20 distinct authors.
- ≥ 10 genuine inbound enquiries per week arriving by WhatsApp or phone.
  Until people are actually messaging, this is tooling for a queue of zero.
- Launch blockers B2–B7 in `launch-readiness-sprint.md` closed. The app is not
  launched; an acquisition funnel that ends at an unlaunched app leaks.

The third condition matters most. Build the operator tool when manual handling
becomes the bottleneck, not before. Until then a WhatsApp enquiry is answered by
a person typing a reply, and that is correct — it costs nothing and it teaches
us what people actually ask for.

## 5. The MVP, when the time comes

Deliberately small.

**Placement.** Not a new sidebar section. The dashboard already carries 7
top-level groups and ~26 destinations, and the brief is explicit that it must
not get more crowded. The natural home is a fifth tab inside the existing
**Marketplace** section — `/dashboard/marketplace/direct` — alongside Requests,
Offers, Hiring and Job Matches. It inherits `SectionTabs`, the section header,
and the page chrome for free, and it sits with the other post-shaped surfaces.

**Flow.** One panel, one button, one result list:

```
capture (service, area, budget, urgency, free text)
   -> GET /feed?scope=offers&categories=…&lat=…&lng=…&max_price=…&urgency=…
   -> compact result cards, not a DataTable
   -> operator copies a short summary to paste into WhatsApp
```

**Do not** persist the captured request as a `posts` row. Writing operator-typed
enquiries into the marketplace would pollute the corpus the engine ranks, inflate
the request counts on every dashboard, and create a second class of post with no
owner and no app presence. Keep the capture form ephemeral until there is a
reason to store it.

**Result card** shows only: provider name, service, distance, price, trust
indicators the engine already exposes, and the engine's own `signals[]`
explanation. No new scoring, no new copy invented at the UI layer.

## 6. Recommendation engine integration — field by field

The engine already accepts an anonymous request, which is exactly the operator's
position. Signals that depend on a viewer identity return `null` and are removed
along with their weight (see `ranking/types.ts` on the null contract), so the
ranking stays correct rather than uniformly penalised.

| Request field | How it enters the engine | Kind |
|---|---|---|
| Service / profession | `categories=` (must be a canonical `categories.name`) | filter |
| Location | `lat` / `lng` + `radius_km` | filter + `distance` signal |
| Budget | `max_price=` | filter |
| Urgency | `urgency=` | filter + `urgency` signal |
| Free-text description | `q=` | filter (text index) |
| Preferred time | — | **not supported; drop it** |
| Contact details | — | never sent to the backend |

Signals that fire unchanged with no viewer: `distance`, `urgency`, `freshness`,
`reliability`, `engagement`, `availability`, `trust`, `timeOfDay`, `staleness`.

Signals that correctly drop out: `profession`, `skills`, `behaviour`,
`searchHistory`, `ownPost`, `alreadyApplied`.

**Backend change required: none.** `GET /feed` is `@Public` and already serves
anonymous callers. The only new work is a server-side fetch from the admin app,
which today talks to the backend only for disputes.

### 6.1 Off-catalogue categories are a feature, not drift — verified

An earlier draft of this document claimed that posts filed under names outside
the `categories` catalogue were unreachable by any filtered search. **That was
wrong, and it is corrected here.**

Nine posts across eight names sit outside the catalogue: `Cleaning` (2),
`Nyama Choma`, `Teaching`, `Cooking`, `Delivery`, `Posho Mill Grinding`,
`Repair`, `IT`. They are there by design. A provider may file a post under their
own profession — see `mobile-app/test/custom_category_test.dart`, whose contract
is that an unknown name "must round-trip … WITHOUT being collapsed to 'Other'" —
validated through `Category.normalizeCustomName` (3–40 chars, must contain a
letter, whitespace collapsed).

They are reachable. Measured against the live API on 2026-09-12:

| `categories=` | candidates |
|---|---|
| Cleaning | 2 |
| Cooking | 1 |
| Delivery | 1 |
| Posho Mill Grinding | 1 |
| Repair | 1 |
| Nyama Choma | 0 — **archived**, correctly excluded |

The one apparent miss is a post archived 28 seconds after it was created. The
feed is right to drop it.

The case-sensitivity hazard is real but already closed in the client.
`Category.resolveFilterName` folds a typed name against the registry *and* the
names the feed has actually returned this session, so "cleaning" is sent as
"Cleaning". The code comment records the same production measurement:
`'Cleaning' → 2 posts, 'cleaning' → 0`. `AppProvider.knownCategoryNames`
accumulates the corpus rather than reading the filtered page, which is what makes
resolution work while a filter is already in force.

Database state is clean: zero case collisions, zero untrimmed or double-spaced
values, zero case mismatches against the catalogue.

**No action required.** The only thing an operator UI would need to respect is
that the category filter is exact and case-sensitive server-side, so it must send
a resolved spelling — exactly as the app already does.

## 7. Risks this defers

- **Support burden.** A manual channel with no SLA becomes an expectation. Every
  enquiry answered by hand is a promise to answer the next one.
- **Second marketplace.** If operators keep matching people by hand, the app
  stops being the product. The workflow must always end at "download Help24",
  never at "message us again".
- **No escrow, no tracking, no dispute cover.** A job matched over WhatsApp and
  done off-platform carries none of Help24's protections, but carries Help24's
  name. That is reputational exposure with no revenue attached.

## 8. What to do instead, now

The binding constraint is provider supply, and no admin tooling changes it.
Provider recruitment in one Mombasa neighbourhood, plus closing the launch
blockers, moves the product. A Find Providers button does not.
