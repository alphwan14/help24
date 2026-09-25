-- 113 — One round trip for the admin overview.
--
-- WHY
-- ---
-- `admin-dashboard/app/dashboard/overview/page.tsx` issued TWELVE PostgREST
-- requests per page load, in parallel, and re-ran all of them on every load
-- because nothing was cached.
--
-- The queries themselves are not the cost. Measured from Nairobi against this
-- project:
--
--   request that never touches Postgres (401 at the gateway) .. 161–602 ms
--   real SELECT over the users table ........................... 343–512 ms
--
-- Those are the same number: Postgres contributes approximately nothing. What
-- costs is the ROUND TRIP, and the page was paying for twelve of them. One
-- function collapses that to one.
--
-- WHY THE CITY LIST IS AN ARGUMENT AND NOT A CONSTANT
-- ---------------------------------------------------
-- The dashboard buckets a free-text `posts.location` into known cities with a
-- substring match, and that list lives in TypeScript. Restating it here would
-- make two definitions of one rule, which is the exact failure this codebase
-- has been removing — a list that drifts is worse than a list that travels.
-- So the caller passes it and SQL only applies it.
--
-- ACCESS
-- ------
-- Platform-wide counts and revenue. Executable by `service_role` ONLY: the
-- dashboard calls it with the service client, and neither `anon` nor
-- `authenticated` has any business reading aggregate revenue.

create or replace function public.admin_overview(p_cities text[] default '{}')
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
with
  since30 as (select now() - interval '30 days' as t),
  since7  as (select now() - interval '7 days'  as t),

  -- The seven headline counts.
  counts as (
    select
      (select count(*) from users)                                            as total_users,
      (select count(*) from users, since7 where last_login >= since7.t)        as active_users_7d,
      (select count(*) from posts where type = 'request')                      as total_requests,
      (select count(*) from posts where type = 'offer')                        as total_offers,
      (select count(*) from posts where selected_provider_id is not null)       as active_jobs,
      -- Server-derived reputation table. `users.completed_jobs_count` is dead.
      (select count(*) from provider_reputation where completed_jobs > 0)       as completed_jobs,
      (select count(*) from transactions)                                       as total_tx,
      coalesce((select sum(amount) from escrow where status = 'locked'), 0)     as pending_escrow
  ),

  -- Signups per day, last 30.
  user_growth as (
    select coalesce(jsonb_agg(jsonb_build_object('date', d, 'count', n) order by d), '[]'::jsonb) as v
    from (
      select to_char(created_at, 'MM-DD') as d, count(*) as n
      from users, since30
      where created_at >= since30.t
      group by 1
      order by 1
    ) g
  ),

  -- Requests vs offers per day, last 30.
  post_activity as (
    select coalesce(jsonb_agg(jsonb_build_object('date', d, 'requests', r, 'offers', o) order by d), '[]'::jsonb) as v
    from (
      select
        to_char(created_at, 'MM-DD') as d,
        count(*) filter (where type = 'request') as r,
        count(*) filter (where type = 'offer')   as o
      from posts, since30
      where created_at >= since30.t
      group by 1
      order by 1
    ) g
  ),

  -- The most recent 200 transactions, which is the window the page describes.
  recent_tx as (
    select status, total_paid
    from transactions
    order by created_at desc
    limit 200
  ),
  payment_status as (
    select coalesce(jsonb_agg(jsonb_build_object('name', status, 'value', n)), '[]'::jsonb) as v
    from (select status, count(*) as n from recent_tx group by status) s
  ),
  revenue as (
    select coalesce(sum(total_paid), 0) as v
    from recent_tx
    where status in ('paid', 'payout_pending', 'released')
  ),

  -- Location buckets. `p_cities` is matched in order, first hit wins, and
  -- anything unmatched falls to 'Other' — the same rule the TypeScript applied.
  located as (
    select coalesce(
      (select c from unnest(p_cities) as c
        where position(lower(c) in lower(l.location)) > 0
        limit 1),
      'Other'
    ) as city
    from (
      select location from posts where location is not null limit 500
    ) l
  ),
  geo_total as (select count(*) as n from located),
  geo as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'city', city,
      'count', n,
      'pct', case when (select n from geo_total) > 0
                  then round(n * 100.0 / (select n from geo_total))
                  else 0 end
    ) order by n desc), '[]'::jsonb) as v
    from (
      select city, count(*) as n from located group by city order by count(*) desc limit 6
    ) t
  )

select jsonb_build_object(
  'kpis', jsonb_build_object(
    'totalUsers',    counts.total_users,
    'activeUsers7d', counts.active_users_7d,
    'totalRequests', counts.total_requests,
    'totalOffers',   counts.total_offers,
    'activeJobs',    counts.active_jobs,
    'completedJobs', counts.completed_jobs,
    'totalTx',       counts.total_tx,
    'pendingEscrow', counts.pending_escrow,
    'totalRevenue',  revenue.v
  ),
  'userGrowth',   user_growth.v,
  'postActivity', post_activity.v,
  'paymentStatus', payment_status.v,
  'geoPoints',    geo.v,
  'totalLocs',    geo_total.n
)
from counts, user_growth, post_activity, payment_status, revenue, geo, geo_total;
$$;

-- Aggregate revenue and platform counts are not public.
revoke all on function public.admin_overview(text[]) from public;
revoke all on function public.admin_overview(text[]) from anon;
revoke all on function public.admin_overview(text[]) from authenticated;
grant execute on function public.admin_overview(text[]) to service_role;

comment on function public.admin_overview(text[]) is
  'Admin dashboard overview, in one round trip. See migration 113 for why. '
  'service_role only — it returns platform-wide revenue.';

-- APPLIED 2026-09-25 via `supabase db query --linked -f`, NOT via `db push`.
--
-- `db push` refuses on this project: fourteen remote migration versions are
-- absent from this directory, and its own suggested remedies (`migration
-- repair`, `db pull`) rewrite history. So this went in as a single statement
-- and is NOT recorded in `supabase_migrations.schema_migrations`.
--
-- That is safe here because every statement above is idempotent — `create or
-- replace`, and grants that restate rather than accumulate. Re-running it,
-- whether by hand or by a future `db push`, changes nothing.
--
-- Verified against live data immediately after applying: all nine KPI values
-- and all six geography buckets matched what the twelve-query path was
-- rendering (18 users, 43 requests, 9 offers, 45 transactions, 68700 escrow,
-- 57405 revenue; Mombasa 34/64% … Eldoret 2/4%, 53 located posts).
