-- The two tables migration 129 touches that replica_schema.sql does not carry,
-- recreated exactly as they are live (read 2026-10-29): columns, RLS, policies
-- and grants. Idempotent, because the harness applies every file twice.

-- The replica prelude has auth.jwt() but not auth.role(); this is Supabase's.
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;
grant execute on function auth.role() to anon, authenticated, service_role;

create table if not exists public.providers (
  id uuid primary key default gen_random_uuid(),
  name text,
  phone_login text,
  phone_payout text,
  services jsonb,
  location text,
  payout_verified boolean,
  created_at timestamptz default now()
);
alter table public.providers enable row level security;
drop policy if exists "Enable all access for authenticated users" on public.providers;
drop policy if exists "Enable read access for all users" on public.providers;
create policy "Enable all access for authenticated users" on public.providers for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "Enable read access for all users" on public.providers for select using (true);
grant select on public.providers to anon, authenticated;
grant all on public.providers to service_role;

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id text,
  sender_temp_id text,
  sender_user_id text,
  receiver_temp_id text,
  receiver_user_id text,
  content text,
  created_at timestamptz default now(),
  type text,
  latitude double precision,
  longitude double precision,
  live_until timestamptz
);
alter table public.messages enable row level security;
drop policy if exists messages_insert on public.messages;
drop policy if exists messages_select on public.messages;
drop policy if exists messages_participant on public.messages;
create policy messages_insert on public.messages for insert with check (true);
create policy messages_select on public.messages for select using (true);
create policy messages_participant on public.messages for all to authenticated
  using (((auth.jwt() ->> 'user_id') = sender_user_id) or ((auth.jwt() ->> 'user_id') = receiver_user_id))
  with check (((auth.jwt() ->> 'user_id') = sender_user_id) or ((auth.jwt() ->> 'user_id') = receiver_user_id));
grant delete, insert, references, select, trigger, truncate, update on public.messages to authenticated;
grant all on public.messages to service_role;
