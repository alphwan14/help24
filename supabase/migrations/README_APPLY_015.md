# Apply migration 015 (relax chats RLS)

If `npx supabase db push` didn't run (no linked project or CLI issues), apply the SQL manually:

1. Open [Supabase Dashboard](https://supabase.com/dashboard) → your project.
2. Go to **SQL Editor**.
3. Copy the contents of `015_relax_chats_messages_rls.sql`.
4. Paste into the editor and click **Run**.

Done. "Contact Provider" and messaging will work with the anon key.
