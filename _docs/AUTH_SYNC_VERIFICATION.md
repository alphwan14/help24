# Firebase → Supabase Auth Sync – Verification

## 1. Run SQL in Supabase (once)

1. Open [Supabase Dashboard](https://supabase.com/dashboard) → your project → **SQL Editor**.
2. Open the file **`supabase/migrations/001_users_table.sql`** in this repo.
3. Copy its entire contents and paste into the SQL Editor.
4. Click **Run**. You should see "Success. No rows returned" (or similar).
5. In **Table Editor**, confirm table **`public.users`** exists with columns:  
   `id`, `phone_number`, `email`, `name`, `profile_image`, `created_at`, `last_login`.

---

## 2. Storage (profile images)

- Bucket: **post-images** (existing).
- Path: **avatars/{userId}.{ext}**.
- The app uses **bytes upload** (no `dart:io` File on web). No extra setup if the bucket already allows uploads.

---

## 3. Confirmation steps (do in order)

### A. Phone signup → user in Supabase

1. Run the SQL above (if not already done).
2. Run the app: `flutter run -d chrome` (or device).
3. Open auth (e.g. try to post, or Profile → Sign In).
4. Choose **Continue with Phone** → enter a real phone number → get OTP → verify.
5. If new user, complete **profile setup** (name, optional photo) → Continue.
6. In Supabase **Table Editor** → **users**: you should see **one new row** with:
   - `id` = Firebase UID (long string)
   - `phone_number` = your number (e.g. +254…)
   - `email` = empty or null
   - `name` = what you entered (or empty)
   - `profile_image` = URL if you added a photo, else null
   - `created_at` and `last_login` set.

**Expected:** One row per phone signup, no crash, no silent failure.

---

### B. Email signup → user in Supabase

1. Sign out (Profile → Log out) if needed.
2. Open auth again → **Continue with Email** → **Sign Up** tab.
3. Enter name, email, password, confirm password → Create account.
4. In Supabase **users** table: **one new row** with:
   - `id` = Firebase UID
   - `email` = your email
   - `phone_number` = null
   - `name` = what you entered
   - `created_at` and `last_login` set.

**Expected:** One row per email signup, no duplicate, no crash.

---

### C. Login again → no duplicate

1. Sign out.
2. Sign in again with the **same** email (or same phone) you used above.
3. In Supabase **users**: **still one row** for that user (same `id`).
4. `last_login` should be updated; `created_at` unchanged.

**Expected:** No second row; upsert updates existing row (e.g. `last_login`), no duplicate users.

---

## 4. If something fails

- **Sync errors in app:** Check Supabase **Table Editor** → **users** exists and column names match the SQL (`profile_image`, not `photo_url`, unless you added a compatibility column).
- **RLS:** The SQL creates policies for `anon` and `authenticated` (SELECT, INSERT, UPDATE). If you use a different auth model, adjust policies.
- **No row after signup:** Check browser/IDE console for `❌ Supabase sync: ...` and fix the error (e.g. missing column, RLS blocking).

---

## Summary

| Step | Do this | Expect this |
|------|--------|-------------|
| SQL | Run `001_users_table.sql` in Supabase SQL Editor | Table `users` exists with correct columns |
| Phone signup | Sign up with phone → verify → profile setup | One new row in `users`, `phone_number` set |
| Email signup | Sign up with email | One new row in `users`, `email` set |
| Login again | Sign in with same phone/email | Same single row, `last_login` updated, no duplicate |

Firebase handles auth; Supabase stores user rows; sync runs after every successful Firebase sign-in/sign-up (and on app load for current user). No RPC; all sync is client-side Supabase `upsert`.
