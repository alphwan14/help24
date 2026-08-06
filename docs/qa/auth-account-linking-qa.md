# Production QA checklist — auth account linking

Covers the change that made a credential stop minting accounts: a second sign-in
method is **linked onto the current uid**, never used to create a new one.

Run on a real device against production. Record PASS/FAIL per row — a row with no
result is not a pass.

Legend: **[R]** reachable in the shipped UI · **[N]** no UI entry point yet
(code exists, cannot be exercised by a tester).

---

## A. The incident itself

The original report: a user who had signed up with Google typed their email and a
new password, and was told their password was wrong — with an offer to reset a
password that never existed.

| # | Scenario | Expected |
|---|---|---|
| A1 **[R]** | Google-only account. Enter that email → type any password → Submit. | One honest failure: no password on this account. The recovery action is **Continue with Google** — *not* a password reset. |
| A2 **[R]** | Same, then tap **Continue with Google** and complete Google. | Signed in. Because a valid password was typed and the Google email matches what was typed, the **Add password** step appears. |
| A3 **[R]** | On **Add password**, confirm. | Password is *linked* to the same uid. Not a new account: same id, same posts, same applications. |
| A4 **[R]** | Sign out. Sign in with email + the password just added. | Signed in to the *same* account. |
| A5 **[R]** | Repeat A2 but type a password that fails validation. | No **Add password** step. Signed in via Google, straight through. |
| A6 **[R]** | Repeat A2 but complete Google with a *different* email than typed. | No **Add password** step. The typed password is discarded, never linked to the wrong identity. |
| A7 **[R]** | Google account that **already** has a password → A1 → Continue with Google. | No **Add password** step (guard: no existing password). |

## B. Identity is preserved, not duplicated

| # | Scenario | Expected |
|---|---|---|
| B1 **[R]** | Before/after any link: note the uid on Profile. | Unchanged across the whole flow. |
| B2 **[R]** | After linking, open own posts / applications / chats. | All still present and owned. |
| B3 | Query `public.users` for the tester's email. | Exactly one row, before and after. |
| B4 **[R]** | Link a method that is already on another account. | Refused with an honest message. No second row created, no silent takeover. |

## C. Method-pair matrix

| # | Pair | Status |
|---|---|---|
| C1 | Google → add Email/password | **[R]** — the A-series above |
| C2 | Email → add Google | **[N]** — `linkGoogle` exists, no UI entry point |
| C3 | Phone → add Google | **[N]** |
| C4 | Google → add Phone | **[N]** |
| C5 | Email → add Phone | **[N]** — `linkPhone` exists, no UI entry point |

> **Open gap — do not record C2–C5 as passing.** There is no Profile
> "sign-in methods" surface, so those paths cannot be reached by a tester. The
> phone side of the invariant stays open until that screen exists.

## D. Sign-in paths that must not regress

| # | Scenario | Expected |
|---|---|---|
| D1 **[R]** | Existing Google user signs in. | Unchanged. |
| D2 **[R]** | Existing email/password user signs in. | Unchanged. |
| D3 **[R]** | Existing phone user signs in via OTP. | Unchanged. |
| D4 **[R]** | Brand-new user, email + password. | Account created, profile setup runs. |
| D5 **[R]** | Brand-new user, Google. | Account created, profile setup runs. |
| D6 **[R]** | Brand-new user, phone. | Account created, profile setup runs. |
| D7 **[R]** | Genuine wrong password on an account that *does* have one. | Honest failure. Password reset **is** offered here. |
| D8 **[R]** | Password reset end to end, then sign in with the new password. | Works; same uid. |
| D9 **[R]** | Wrong OTP; expired OTP; resend OTP. | Each fails honestly, no account created. |
| D10 **[R]** | Airplane mode mid-sign-in. | Network failure message, not "wrong password". |

## E. Profile row availability

`ensureCurrentUserInSupabase()` now verifies the row exists and throws
`ProfileUnavailableException` instead of reporting success it did not achieve.

| # | Scenario | Expected |
|---|---|---|
| E1 **[R]** | Sign in normally. | Profile loads. No spurious error. |
| E2 **[R]** | Sign in with the backend unreachable (airplane mode after Firebase auth). | The authored `ProfileUnavailableException` copy, not a generic crash and not a silent empty profile. |
| E3 **[R]** | Recover connectivity and retry. | Profile resolves. |

## F. Downstream — the account still works after linking

Run as the **linked** account (A3), not a fresh one.

| # | Area | Check |
|---|---|---|
| F1 | Profile creation / edit | Name, photo, profession save. Name-change cooldown still enforced. |
| F2 | Posting | Create a request and an offer; both appear in Discover with correct authorship. |
| F3 | Applications | Apply to someone else's listing; own listing still refuses self-application. |
| F4 | Messaging | Send and receive; realtime delivery; unread count moves correctly. |
| F5 | Notifications | Push arrives; in-app list and unread badge agree. |
| F6 | Escrow | Fund, release, and the dispute entry point. |
| F7 | Payments | A real low-value transaction end to end. |
| F8 | Reviews | Leave one; provider rating and review count update. |
| F9 | Provider onboarding | Complete it; provider surfaces appear. |
| F10 | Saved items | Save and unsave persist across restart. |

## G. Regression sweep

| # | Check |
|---|---|
| G1 | Cold start holds one launch transaction; no flash of an empty feed. |
| G2 | Discover renders a stable snapshot; cards on screen do not reshuffle. |
| G3 | Sign out fully clears session; relaunch lands on welcome. |
| G4 | Force-quit mid-link, relaunch → coherent state, never a half-linked account. |

---

## Blockers to resolve before this checklist can be called complete

1. **C2–C5 are unreachable.** Needs a Profile → sign-in methods surface.
2. **Live RLS on `public.users` is wide open** — see the DB findings from
   2026-08-06. Any holder of the anon key can update any user row, including
   `role`. This is independent of the linking work but sits on the same table.
3. **Migration 011 is not applied**, and applying it as written would lock the
   three Supabase-Auth-created accounts out of their own profile updates.
