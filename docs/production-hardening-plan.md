# Production hardening plan — identity, RLS, migration history

Status: **awaiting approval. Nothing has been applied to production.**
Every DB statement run so far was read-only.

---

# Priority 1 — Secure `public.users`

## 1.1 The finding, re-verified

Confirmed against live catalog (not inferred from migration files):

| Check | Result |
|---|---|
| RLS enabled on `public.users` | yes (`relrowsecurity = true`, `relforcerowsecurity = false`) |
| `has_table_privilege('anon', …, 'UPDATE')` | **true** |
| `has_table_privilege('anon', …, 'INSERT')` | **true** |
| UPDATE policies whose `USING` is literally `true` | **2** |
| DELETE policies | **0** |

The four policies that create the hole:

| Policy | Cmd | Roles | `USING` | `WITH CHECK` |
|---|---|---|---|---|
| `users_update` | UPDATE | `{public}` | `true` | – |
| `Users update by anon and authenticated` | UPDATE | `{anon,authenticated}` | `true` | `true` |
| `users_insert` | INSERT | `{public}` | – | `true` |
| `Users insert by anon and authenticated` | INSERT | `{anon,authenticated}` | – | `true` |

RLS policies are **permissive** — they OR together, so the loosest wins. Combined
with the table-level grant to `anon`, any holder of the publishable key
`sb_publishable_…` (which ships inside the Android app and is therefore public)
can `UPDATE` or `INSERT` **any row, any column**.

**Correction to the earlier report:** `DELETE` is *not* exploitable. `anon` holds
the DELETE grant, but there are zero DELETE policies and RLS default-denies any
command with no permissive policy. Grant without policy = denied.

## 1.2 Why this is critical rather than cosmetic

`public.users` is the authorization surface for the whole product:

- **`role` → full admin takeover.** `admin-dashboard/middleware.ts` gates access by
  reading `public.users.role`, looked up **by email**. Once past that gate, the
  dashboard's pages query with the **service_role** key, which bypasses RLS
  entirely. So flipping one boolean-ish text column converts a public API key
  into unrestricted database control. (Exploiting this end-to-end also requires a
  Supabase Auth login for the matching email — but `INSERT` is open too, so rows
  can be planted as well as edited.)
- **`is_banned`** — a banned account can unban itself; anyone can ban a competitor.
- **`is_verified`** — forges the verified-identity trust badge, and it feeds feed
  ranking via `backend/src/feed/ranking/signals/trust.signal.ts`.
- **`average_rating` / `total_reviews` / `completed_jobs_count`** — forges reputation
  in a marketplace that carries **escrow and M-Pesa payments**.
- **`email`** — repoints the identity the admin gate keys on.
- **Unconditionally**, today: any profile's name, bio, phone and avatar can be
  rewritten by anyone. That is defacement plus PII overwrite.

## 1.3 Why the obvious fix is the wrong fix

The textbook change is owner-scoped RLS (`id = auth.jwt()->>'user_id'`, i.e.
migration 011). **It would break production**, for three independent reasons:

1. **Signup writes race the token exchange.** `AuthService.verifyOtp` awaits
   `UserProfileService.createUserOnSignup` (a write) at `auth_service.dart:393`,
   while the Firebase→Supabase exchange is fired **unawaited** from
   `auth_provider.dart:148`. The write starts immediately; the exchange must do
   `getIdToken()` plus an edge-function round trip. The write almost always wins,
   so **new-user profile creation runs as `anon` today**. Requiring an identity
   would break signup nondeterministically — the worst failure shape.
2. **The admin dashboard writes from the browser.** `BanToggle.tsx` updates
   `is_banned` using the admin's **Supabase Auth** JWT, whose `sub` is a UUID and
   which carries **no `user_id` claim**. Any policy keyed on `user_id` denies it.
3. **Mobile adoption cannot be forced.** Old installs would keep failing.

Also note `auth.uid()` must never appear in a policy here: it casts `sub` to
`uuid`, and mobile `sub` is a Firebase UID, so it raises rather than returning null.

## 1.4 The minimum correct fix

**Do not touch policies or grants. Add one guard trigger** that makes privileged
columns unwritable by untrusted callers, and move the one legitimate admin write
off the browser.

Column privileges and RLS both fail the "preserve every flow" test here; a
trigger can distinguish *changing* a privileged column from *restating* it, which
is exactly what the deployed client's upsert does.

### Change A — database (one function, one trigger)

```sql
CREATE OR REPLACE FUNCTION public.fn_users_guard_privileged_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_jwt_role text;
BEGIN
  -- Trusted callers pass through: the service_role key (admin dashboard server
  -- actions) and owner/direct connections (SQL editor, migrations, and
  -- SECURITY DEFINER triggers such as handle_new_auth_user).
  v_jwt_role := COALESCE(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '');

  IF v_jwt_role = 'service_role'
     OR current_user IN ('postgres', 'supabase_admin', 'service_role') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    -- Coerce, never refuse: a sign-up must not fail because of this guard.
    -- A client simply does not get to choose its own privileges.
    NEW.role                 := 'user';
    NEW.is_banned            := false;
    NEW.is_verified          := false;
    NEW.average_rating       := NULL;
    NEW.total_reviews        := NULL;
    NEW.completed_jobs_count := NULL;
    RETURN NEW;
  END IF;

  IF NEW.id                   IS DISTINCT FROM OLD.id
  OR NEW.email                IS DISTINCT FROM OLD.email
  OR NEW.role                 IS DISTINCT FROM OLD.role
  OR NEW.is_banned            IS DISTINCT FROM OLD.is_banned
  OR NEW.is_verified          IS DISTINCT FROM OLD.is_verified
  OR NEW.average_rating       IS DISTINCT FROM OLD.average_rating
  OR NEW.total_reviews        IS DISTINCT FROM OLD.total_reviews
  OR NEW.completed_jobs_count IS DISTINCT FROM OLD.completed_jobs_count THEN
    RAISE EXCEPTION 'help24_privileged_column_change_refused'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_guard_privileged_columns
  BEFORE INSERT OR UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.fn_users_guard_privileged_columns();
```

**Why `IS DISTINCT FROM` and not a column revoke.** The deployed client upserts
with `onConflict: 'id'`, which becomes `INSERT … ON CONFLICT DO UPDATE SET
email = …`. A column-level revoke would refuse that statement even though the
value is unchanged, breaking sign-in for every existing user. Comparing values
lets the restatement through and stops only real changes.

**Evidence that nothing legitimate is refused** — searched, not assumed:

- The Flutter app never writes `role`, `is_banned`, `is_verified`, or any
  reputation column to `users`. The only matches are reads/serialisation on the
  separate `provider_reputation` model.
- `fn_recompute_provider_reputation` writes `provider_reputation`, **not**
  `public.users` (verified against its body) — so reputation recompute is
  unaffected even though it is SECURITY INVOKER.
- `is_verified` has no writer at all in app or backend; it is set by hand by an
  operator (`_docs/RECOMMENDATION_ENGINE_TESTING.md:137`).
- `handle_new_auth_user` is SECURITY DEFINER owned by `postgres` → bypasses.
- `updateUserRole` already runs service_role server-side → bypasses.
- **`BanToggle.tsx` is the sole exception** → Change B.

### Change B — admin dashboard (code, no DB)

Add `setUserBanned` to `admin-dashboard/app/dashboard/users/actions.ts`, mirroring
the existing `updateUserRole`: resolve the caller from the session cookie,
re-verify `role = 'admin'` from the DB with the service client, then write with
service_role. Rewire `BanToggle.tsx` to call it instead of
`getSupabaseBrowser().from("users").update(...)`.

This *improves* admin security independently: banning currently has *no*
server-side authorization check at all — the browser just issues an update.

### Ordering (matters)

**Change B ships before Change A.** If the trigger lands first, banning breaks
until the dashboard deploys.

## 1.5 What this fix does *not* do

Honest scope. After this, an anonymous caller **can still** rewrite any user's
`name`, `bio`, `phone_number`, `avatar_url`, `profession`. That is defacement and
PII overwrite, and it is not acceptable as an end state. It cannot be closed
without the client fix in Priority 2 (await the token exchange before the first
write), because closing it means requiring an identity. Sequence:

- **Now:** stop privilege escalation and reputation forgery (this change).
- **Next:** fix the client write-ordering race, ship it, measure adoption.
- **Then:** owner-scoped RLS accepting **both** id shapes, replacing the
  `USING true` policies.

## 1.6 Rollback

```sql
DROP TRIGGER IF EXISTS trg_users_guard_privileged_columns ON public.users;
DROP FUNCTION IF EXISTS public.fn_users_guard_privileged_columns();
```

Instant, and it touches **no data and no rows** — the change is purely a
gatekeeper. Revert the dashboard commit to restore `BanToggle`'s old behaviour.
No migration of data means no rollback window and no backup dependency.

## 1.7 Risk

| Risk | Severity | Mitigation |
|---|---|---|
| An unfound legitimate writer gets refused | Medium | Searched app, backend, dashboard, and all DB functions; only `BanToggle` found. The error is distinctive (`help24_privileged_column_change_refused`) so it is unambiguous in logs. |
| `BanToggle` breaks | High if misordered | Ship Change B first. |
| `current_setting('request.jwt.claims')` shape differs | Low | Guard also accepts `current_user IN (postgres, supabase_admin, service_role)`; verified post-apply by an actual service_role write. |
| Signup regression | Low | INSERT path **coerces** instead of refusing, so it cannot fail. |
| Performance | Negligible | Row-level trigger on a 16-row table with low write volume. |

## 1.8 Post-apply verification (read-only unless noted)

1. Re-run the privilege/policy queries — expect **unchanged** (we changed neither).
2. Confirm trigger exists and is enabled.
3. **Negative test (write, will be rolled back):** as `anon`, attempt
   `UPDATE public.users SET role='admin'` inside `BEGIN … ROLLBACK` — expect
   `help24_privileged_column_change_refused`.
4. **Positive test:** service_role sets and restores `is_banned` on a test row.
5. Exercise the app: edit name, bio, profession → all must still save.

---

# Priority 2 — Unify Help24 identity

## 2.1 Canonical identity: the Firebase UID

| Evidence | Weight |
|---|---|
| 13 of 16 `users` rows are Firebase UIDs | – |
| 100% of app data (posts, applications, messages, skills) hangs off Firebase UIDs | decisive |
| The token bridge already mints `user_id = <Firebase UID>` | decisive |
| All RLS intent (migration 011) keys on `user_id` | – |
| The 3 UUID rows own **zero** posts, applications, messages or skills | – |

**Firebase UID is canonical.** Supabase Auth is not a competing identity — it is
the *admin dashboard's login mechanism*. The defect is that a login mechanism was
wired to mint a **Help24 identity**.

## 2.2 The actual defect

`on_auth_user_created` on `auth.users` calls `handle_new_auth_user`, which inserts
a `public.users` row keyed by the Supabase UUID. So creating a dashboard account
creates a *person* in the marketplace. That is the ambiguity to remove.

Two live consequences:

1. Three `public.users` rows are dashboard identities masquerading as members —
   including `zurinsojars@gmail.com`, which is `role = 'admin'`.
2. `handle_new_auth_user` inserts `ON CONFLICT (id) DO NOTHING`, but the table has
   `users_email_unique`. An email already held by a Firebase row therefore raises
   a unique violation that **rolls back the entire `auth.users` insert** — so
   inviting an existing member to the dashboard fails with a raw DB error. The
   two oldest `auth.users` rows (`alphwan14@`, `alphlincoln18@`) predate the
   trigger, which is why they have no mirrored row.

## 2.3 Target model

> One person = one `public.users` row, keyed by Firebase UID.
> A Supabase Auth account is a **credential for the dashboard**, linked to a
> Help24 identity by email — never mirrored into a new row.

## 2.4 Migration — no deletes, no automatic merges

**Step 1 — stop the bleeding.** Drop `on_auth_user_created`. New dashboard
accounts stop minting marketplace identities.
*Consequence to accept:* a new admin must already have a Help24 row (created by
using the app), and an operator then sets `role='admin'` via the existing
service_role server action. Document as the admin onboarding runbook.
*Rollback:* recreate the trigger — it is one statement.

**Step 2 — make the linkage explicit.** New table:

```
user_auth_identities(
  help24_user_id text references users(id) on delete cascade,
  provider       text  check (provider in ('firebase','supabase')),
  subject        text,                     -- Firebase UID or auth.users.id
  linked_at      timestamptz default now(),
  primary key (provider, subject)
)
```

Backfill from what exists: one `firebase` row per Firebase-UID user, one
`supabase` row per matching `auth.users` id. **No merging** — where one email has
both a Firebase row and an unmatched `auth.users` row (the two owner accounts),
record both and let them point at the Firebase identity only after a human
approves each one.

**Step 3 — the three dashboard-only rows.** Do not delete, do not merge. They own
no data. If that person later signs into the app with Firebase using the same
email, `users_email_unique` will reject the signup — that is the case requiring a
deliberate, approved, audited merge. Ship a **runbook**, not automation.

**Step 4 — retire the email-keyed admin gate.** `middleware.ts` resolving admins
by email is what turns an email rewrite into privilege escalation. Once
`user_auth_identities` exists, resolve the admin's Help24 identity through it.

## 2.5 Backwards compatibility

Nothing in the mobile app reads `auth.users`. The dashboard reads `public.users`
by email and keeps working. Dropping the trigger changes no existing row. Steps 1
and 2 are additive and independently reversible; Step 4 is a dashboard deploy.

---

# Priority 3 — Repair migration history

## 3.1 What is actually true

`supabase_migrations.schema_migrations` returns **zero rows**, while the live
schema clearly contains objects from many migration files. Everything live was
applied by hand in the SQL editor. So today a migration file is evidence of
*intent*, never of *state* — which is exactly how migration 011 came to be
believed applied when it never was.

## 3.2 Rules

- **Never** mark a file applied without verifying its objects exist live.
- **Never** run `db push` against production before the ledger is reconciled — it
  would replay everything and fail (or worse, partially succeed).

## 3.3 Strategy — evidence first, then adopt

**Step 1 — build an evidence report.** For each file in `supabase/migrations/`,
extract the objects it creates (tables, columns, policies, functions, triggers,
indexes) and check each against the live catalog. Classify:

| Class | Meaning | Action |
|---|---|---|
| **Fully applied** | every object present | safe to record as applied |
| **Not applied** | no object present | leave unrecorded; apply later, in order |
| **Partially applied** | some present | **the dangerous class** — needs per-file adjudication |

Migration 011 is already known to be **Not applied**. The 077–083 and 086/087
backlog needs classifying by this method rather than by memory.

**Step 2 — adopt, don't fabricate.** For *Fully applied* files only, record the
version via `supabase migration repair --status applied <version>`. This is
Supabase's documented mechanism for adopting an existing database, and recording
a **verified** fact is not fabrication.

**Step 3 — resolve partials honestly.** Never mark them applied. Either split the
file so the applied part can be recorded and the rest re-applied, or write a new
forward "reconcile" migration that is idempotent (`IF NOT EXISTS`, `DROP POLICY
IF EXISTS` then `CREATE`). Prefer the forward migration — it leaves a truthful
trail.

**Step 4 — alternative if partials dominate: baseline squash.** `supabase db dump`
the live schema to `000_baseline.sql`, record it as the single applied migration,
and archive prior files under `supabase/migrations/_pre-baseline/`. Loses per-file
history but yields a ledger that is true on day one. **Recommended if Step 1
shows more than a handful of partials** — a truthful baseline beats a
half-reconstructed history.

**Step 5 — keep it true.** All future changes via `supabase db push` (or
`apply_migration`, which records the ledger row). Add a CI drift check
(`supabase db diff --linked`) that fails when live and files disagree.

## 3.4 What I propose to do first

Produce the Step 1 evidence report — read-only, no writes — so the adopt/reconcile
decision rests on data. That report is also the only trustworthy way to settle
which of 077–083, 086, 087 are genuinely outstanding.

---

# Authentication verification — sequencing

Full verification must run **after** approval and apply, and it needs hardware:
`adb` is installed but **no device is currently connected**.

What I can do without a device: the analyzer and 670-test suite, the live DB
assertions in §1.8, and a service_role/anon differential test.
What needs the device: every row in the QA checklist below.

Connect a device (or start an emulator) and I will drive the runs via `adb`,
capture logcat around each `[AUTH]` marker, and report actual results — as in the
earlier investigation where a trace settled what three rounds of code reasoning
could not.

---

# Decisions I need from you

1. **Approve Priority 1** (Change B then Change A) — or ask for revisions.
2. **Priority 2 Step 1** — dropping `on_auth_user_created` changes admin
   onboarding to "use the app first, then get promoted". Confirm that is
   acceptable.
3. **Priority 3** — should I produce the evidence report next (read-only)?
4. Whether to create numbered migration **files** for these changes now, or only
   at apply time, given the ledger is being reconciled.
