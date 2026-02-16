# Real-time messaging setup

## 1. Run SQL in Supabase

1. Open **Supabase Dashboard** → your project → **SQL Editor**.
2. Copy the contents of **`supabase/migrations/002_messaging.sql`** and run it.
3. If you see **"permission denied for table conversations" (42501)** in the app, run **`supabase/migrations/002b_messaging_grants.sql`** in the SQL Editor to grant anon/authenticated access.
4. In **Database → Replication**, add the **`messages`** table to the **supabase_realtime** publication so INSERT events are broadcast.

## 2. Flow

- **Conversations** are created only when:
  - A **request/application is accepted** (Discover → open post → Responses → **Accept** on an application), or
  - A **job application is accepted** (when that UI is added).
- **Messages** use Supabase Realtime: new messages appear on both sides without refresh.
- **Pagination**: older messages load when you scroll to the top (50 per page).

## 3. Test with two users

1. User A: create a post (request/offer), get an application from User B.
2. User A: open post → Responses → **Accept** on B’s application → Chat opens.
3. User B: open **Messages** → open the conversation with A.
4. Send messages from A and B; they should appear in real time on both devices.
