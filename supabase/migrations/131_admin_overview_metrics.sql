-- 131 — admin_overview counts what its cards say.
--
-- Found in the 2026-10-29 pre-launch audit by comparing each Overview card with
-- the table it claims to describe (read-only, production):
--   * "Active Jobs" counted every post that ever had a provider selected —
--     19, of which 9 were already completed. Active means a provider is on it
--     and it has not finished: status assigned or disputed (10).
--   * "Completed Jobs" counted provider_reputation rows with completed_jobs > 0
--     — the number of PROVIDERS who have finished at least one job (1), not the
--     number of jobs completed (9 posts with status completed).
--   * "Total Revenue" summed total_paid — what customers paid, provider
--     earnings included — and only over the latest 200 transactions, so it
--     would silently stop being all-time at the 201st. Help24's revenue is the
--     fee. Both are now returned, over every paid transaction.
--
-- The dashboard (app/dashboard/overview/page.tsx) reads paymentsVolume and
-- platformFees, and treats a result without paymentsVolume as this function's
-- pre-131 version — it then computes the corrected figures itself. So the
-- dashboard and this migration can ship in either order. totalRevenue is kept,
-- equal to paymentsVolume, for the dashboard build that is deployed today;
-- remove it once the new dashboard is live.
--
-- Read-only function, same signature, grants unchanged (CREATE OR REPLACE).
-- Rollback: re-run the previous definition (pg_get_functiondef before applying,
-- or migration 113).

create or replace function public.admin_overview(p_cities text[] default '{}'::text[])
returns jsonb
language sql
stable
set search_path to 'public'
as $function$
with
  since30 as (select now() - interval '30 days' as t),
  since7  as (select now() - interval '7 days'  as t),

  counts as (
    select
      (select count(*) from users)                                            as total_users,
      (select count(*) from users, since7 where last_login >= since7.t)        as active_users_7d,
      (select count(*) from posts where type = 'request')                      as total_requests,
      (select count(*) from posts where type = 'offer')                        as total_offers,
      -- A provider is on it and it has not finished; a dispute is unresolved work.
      (select count(*) from posts
        where selected_provider_id is not null and status in ('assigned', 'disputed')) as active_jobs,
      -- Jobs, not the providers who did them.
      (select count(*) from posts where status = 'completed')                  as completed_jobs,
      (select count(*) from transactions)                                       as total_tx,
      coalesce((select sum(amount) from escrow where status = 'locked'), 0)     as pending_escrow
  ),

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

  -- The status chart describes the most recent 200 transactions.
  recent_tx as (
    select status
    from transactions
    order by created_at desc
    limit 200
  ),
  payment_status as (
    select coalesce(jsonb_agg(jsonb_build_object('name', status, 'value', n)), '[]'::jsonb) as v
    from (select status, count(*) as n from recent_tx group by status) s
  ),

  -- Money: every transaction in which a customer's payment was really taken.
  paid as (
    select coalesce(sum(total_paid), 0) as volume, coalesce(sum(fee), 0) as fees
    from transactions
    where status in ('paid', 'payout_pending', 'released')
  ),

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
    'totalUsers',     counts.total_users,
    'activeUsers7d',  counts.active_users_7d,
    'totalRequests',  counts.total_requests,
    'totalOffers',    counts.total_offers,
    'activeJobs',     counts.active_jobs,
    'completedJobs',  counts.completed_jobs,
    'totalTx',        counts.total_tx,
    'pendingEscrow',  counts.pending_escrow,
    'paymentsVolume', paid.volume,
    'platformFees',   paid.fees,
    -- Deprecated: read by the dashboard build deployed before 131.
    'totalRevenue',   paid.volume
  ),
  'userGrowth',    user_growth.v,
  'postActivity',  post_activity.v,
  'paymentStatus', payment_status.v,
  'geoPoints',     geo.v,
  'totalLocs',     geo_total.n
)
from counts, user_growth, post_activity, payment_status, paid, geo, geo_total;
$function$;
