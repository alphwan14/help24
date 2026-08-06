# Priority 3 Step 1 — migration evidence report

Produced 2026-08-06. **Read-only**: every statement behind this report was a
catalog query. Nothing here has been recorded, repaired or squashed.

`supabase_migrations.schema_migrations` returns **zero rows**. Everything live
was applied by hand in the SQL editor. This report replaces memory with evidence.

## Method

1. Parse all 93 `.sql` files in `supabase/migrations/` and extract every object
   each one *declares it creates* — tables, columns, constraints, indexes,
   policies, functions, triggers, views. **450 declared objects.**
2. Compare each against the live catalog (`pg_class`, `pg_policy`, `pg_proc`,
   `pg_trigger`, `pg_constraint`, `information_schema.columns`), covering the
   `public`, `auth`, `storage` and `identity` schemas.
3. Classify per file, then **adjudicate every gap by hand** — see the caveat
   below, which is the most important part of this report.

### The caveat that changes how you read the table

A declared object being absent has **two** possible causes, and the automated
comparison cannot tell them apart:

- the file was never applied, **or**
- the file *was* applied and a **later migration deliberately replaced or
  dropped** its objects.

Most gaps here are the second kind. Every one below was adjudicated individually
against the later migration that superseded it, so the "genuinely outstanding"
list at the end is small and trustworthy.

> **Parser note, stated for honesty.** The first version of this scan reported
> 382 objects and wrongly marked 019 as declaring no tables. Cause: it stripped
> dollar-quoted blocks *before* comments, so the literal text `DO $$ guards` in
> 019's header comment paired with the real `DO $$` further down and swallowed
> the statements between them. Fixed by stripping comments first and stripping
> only function bodies (`AS $tag$ … $tag$`), never `DO` blocks — several
> migrations wrap real DDL in `DO $$ BEGIN … END $$` idempotency guards. The
> numbers below are from the corrected run.

---

## 1. Headline result

| Class | Files | Meaning |
|---|---:|---|
| **Fully applied** | 66 | every declared object present live |
| **Partial** | 11 | some objects absent — all but two adjudicated as *superseded* |
| **Not applied** | 2 | no objects present — both adjudicated as *superseded* |
| **Declares no objects** | 14 | grants / DML / realtime / drop-only — cannot be judged this way |
| **Total** | **93** | |

**After adjudication only three files are genuinely divergent from live:
011, 019 and 044.** Everything else is either applied or was applied and then
intentionally replaced.

### Correction to the standing backlog

The working assumption has been that **077–083 and 086/087 are pending manual
apply**. That is **wrong**. Verified live:

| File | Believed | Actually |
|---|---|---|
| 077_promotion_schema | pending | **fully applied** (18/18 objects) |
| 078_promotion_events | pending | **fully applied** (6/6) |
| 079_public_provider_reputation | pending | **fully applied** |
| 080_notifications_owner_claim_fix | pending | **fully applied** |
| 082_saved_items | pending | **fully applied** |
| 086_professions | pending | **fully applied** |
| 087_users_name_change_guard | pending | **fully applied** |

081, 083, 085 declare no objects (RLS drop / realtime publication changes) and
are adjudicated separately in §3. There is no 077–087 backlog.

---

## 2. Files needing action

### 2.1 `011_rls_chats_messages_users_storage.sql` — genuinely NOT applied (known)

4 of 13 objects present. The three storage policies and `users_select` exist;
the four owner-scoped `users` policies do **not**:

```
users_insert_own, users_insert_anon, users_update_own    ← absent
```

Live `public.users` still carries `users_update` / `Users update by anon and
authenticated` with `USING true`. This is the finding Priority 1 was built
around, now confirmed by object-level evidence rather than inference.

Its chat policies are a separate matter — superseded by 061 (§3).

**Action: do not apply this file, ever.** Applying it would break signup (see
`production-hardening-plan.md` §1.3). It needs replacing, not running.

### 2.2 `019_payment_tables.sql` — one policy never applied (NEW FINDING)

33 of 34 objects present. Missing: `providers.providers_service_role`.

Live `public.providers` instead carries two **Supabase Studio default policies**
that no migration in this repo created:

| Policy | Cmd | `USING` |
|---|---|---|
| `Enable read access for all users` | SELECT | `true` |
| `Enable all access for authenticated users` | ALL | `auth.role() = 'authenticated'` |

Verified by executing as each role:

```
anon SELECT providers          : READABLE — 2 rows
anon UPDATE providers          : denied [permission denied for table providers]
authenticated UPDATE providers : denied [permission denied for table providers]
```

**Reads are exposed; writes are not.** The write policy looks alarming but is
inert — `anon` and `authenticated` hold only `SELECT` at the table level, and a
policy without a grant denies just as a grant without a policy does.

The live consequence: `providers` holds `phone_login`, `phone_payout` and
`payout_verified`, and **all 2 rows are readable by any holder of the
publishable key**, which ships inside the Android app. That is payout-account
PII disclosure. Small blast radius today (2 rows), and it should not survive
contact with real provider volume.

**Action:** replace both Studio policies with 019's intended
`providers_service_role`, and revoke the `anon`/`authenticated` SELECT grant.
Needs its own approval — it is not covered by anything approved so far.

### 2.3 `044_drop_dead_notification_trigger.sql` — drops only partly landed (NEW FINDING)

This file declares no objects (it is drop-only), so the automated pass could not
classify it. Adjudicated by checking each of its three drops:

| Statement | Live result |
|---|---|
| `DROP TRIGGER message_notification_trigger ON chat_messages` | **applied** — trigger absent |
| `DROP FUNCTION queue_notification_on_message()` | **not applied** — function still exists |
| `DROP TABLE notification_queue` | **not applied** — table exists, **125 rows** |

So 016's trigger is gone but its function and queue table survive. Two
consequences:

- **Not an exposure.** `notification_queue` has RLS *disabled* and zero policies,
  but `anon` and `authenticated` hold **no grants on it at all** — only
  `service_role` does. Confirmed by execution:
  `anon SELECT notification_queue : denied [permission denied for table notification_queue]`.
- **It is dead data.** 125 rows including a `content` column — real message text —
  retained by a queue nothing drains any more. That is a data-retention problem,
  not an access-control one.

**Action:** finish 044 in a forward migration (drop the function, then the
table), after deciding whether those 125 rows need archiving. Needs its own
approval.

---

## 3. Gaps adjudicated as *superseded* — no action needed

Each of these is absent from live because a **later, applied** migration replaced
it. Re-applying any of them would undo a deliberate lockdown.

| File(s) | Absent objects | Superseded by | Evidence |
|---|---|---|---|
| 008, 011, 014, 015, 026 | `chats_select/insert/update`, `chat_messages_select/insert/update` | **061** | live `chats` has exactly one policy, `chats_participant`; `chat_messages` exactly one, `chat_messages_participant` |
| 016 | the six `*_smart` policies | **061** | same — one participant policy per table |
| 016 | `message_notification_trigger` | **044** | 044 drops it by name; trigger absent |
| 002, 003 | `conversations`/`messages` policies | **061** | live has `conversations_participant`, `messages_participant` |
| 022 | `posts_update_author` | **076** | live has `posts_update_owner`, `posts_delete_owner` |
| 039 | `fcm_tokens_owner` | **061** | live has `fcm_tokens_owner_all` |
| 042 | `sender_can_soft_delete` | **081** | 081 drops it by name, with a written rationale (the `auth.uid()` cast explodes on Firebase UIDs) |
| 051 | `uniq_admin_invites_pending_email` | **053** | live has `uniq_admin_invites_active_email` |

Note on 002: live `messages` carries `messages_select` / `messages_insert`
(underscores), while 002 declared `Messages select` / `Messages insert`
(spaces). Different names, same intent — the live pair was created outside this
repo's files.

## 4. Files that declare no objects (14)

Cannot be classified by object presence. Judged by reading them:

| File | Kind | Verdict |
|---|---|---|
| 002b_messaging_grants | grants | assume applied — messaging works |
| 006_clean_data_reset | DML (`DELETE FROM`) | one-shot, never replay |
| 028_cleanup_empty_chats | DML | one-shot |
| 036_db_cleanup | DML | one-shot |
| 040, 050, 083, 085 | realtime publications | verify via `pg_publication_tables` if it matters |
| 044 | drops | **partially applied — see §2.3** |
| 072, 073, 074 | question-schema seed DML | one-shot |
| 081 | drop policy | applied (policy absent) |
| 096 | seed DML into `feed_settings` | one-shot |

The one-shot DML files are the strongest argument against ever replaying this
directory: `006_clean_data_reset.sql` **deletes every row from `users`,
`posts`, `applications`, `messages` and `conversations`**.

---

## 5. Recommendation — baseline, do not adopt file-by-file

The plan offered two routes. The evidence points to **Step 4, baseline squash**,
not Step 2 adopt-file-by-file. Reasoning:

**The blocking problem is not the partial count — it's that this directory must
never be replayed.** Replaying it against a fresh database does not reproduce
production, it produces something worse:

- `006_clean_data_reset.sql` truncates the marketplace.
- `011` applies owner-scoped `users` RLS, which breaks signup.
- `008/014/015/026` re-open chat RLS that `061` deliberately closed.
- `042` recreates the policy `081` removed for a documented reason.

That already bites today: Supabase's **branch creation replays the migrations
directory**, so any dev branch made right now gets a schema that differs from
production in its entire authorization surface.

Adopting file-by-file would also require recording `011` as *applied* when it
demonstrably is not — the ledger's one job is to tell the truth, and its first
row would be a lie.

**Proposed sequence** (each step needs its own approval; nothing below has been
done):

1. `supabase db dump --schema public,storage,identity` → `000_baseline.sql`.
2. Move all of 001–099 to `supabase/migrations/_pre-baseline/` — kept as
   history, no longer executable. Per-file history is preserved in git and in
   this report.
3. Record `000_baseline` as the single applied migration. That claim is **true
   on day one**, which is the whole point.
4. Land the three genuine divergences as *forward* migrations on top:
   - `101` — replace `providers`' Studio policies, revoke anon/authenticated SELECT (§2.2)
   - `102` — finish 044's drops (§2.3)
   - `011`'s successor — owner-scoped `users` RLS accepting both id shapes, only
     after the client write-ordering fix ships and adoption is measured
     (Priority 1 §1.5 sequence, unchanged)
5. Add the CI drift check (`supabase db diff --linked`) so this can never
   silently rot again.

**What a baseline costs:** you lose the ability to `db push` an individual
historical file, and per-file provenance moves from the ledger into git plus this
document. Given that replaying any historical file is already unsafe, that
capability is one you cannot use anyway.

---

## 6. Note on 098 and 099

Both were applied today via `execute_sql`, **not** `apply_migration`, so neither
wrote a ledger row. That was deliberate: `apply_migration` stamps a timestamp
version (`20260806…`) while every file here uses an `NNN_` prefix, and seeding a
99-file-empty ledger with one mismatched-format row would have made the
reconciliation strictly harder.

Both are fully applied and verified (2/2 and 3/3 objects present). They fold into
the baseline in step 1 above like everything else.
