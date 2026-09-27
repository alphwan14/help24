-- Trust & Safety rollout — production fingerprints (READ ONLY).
-- Run before and after migrations 114–116: the money and marketplace tables
-- must be byte-identical; only the moderation objects may change.
begin transaction read only;
select 'escrow' as t, count(*)::int as n, coalesce(sum(amount),0)::bigint as total,
       md5(coalesce(string_agg(e::text, '|' order by e.id), '')) as md5 from public.escrow e
union all select 'transactions', count(*)::int, coalesce(sum(total_paid),0)::bigint,
       md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.transactions t
union all select 'disputes', count(*)::int, null, md5(coalesce(string_agg(d::text, '|' order by d.id), '')) from public.disputes d
union all select 'job_completions', count(*)::int, null, md5(coalesce(string_agg(j::text, '|' order by j.id), '')) from public.job_completions j
union all select 'posts', count(*)::int, null, md5(coalesce(string_agg(p.id::text || p.status || coalesce(p.archived_at::text,''), '|' order by p.id), '')) from public.posts p
union all select 'users', count(*)::int, null, md5(coalesce(string_agg(u.id || coalesce(u.is_banned::text,''), '|' order by u.id), '')) from public.users u
union all select 'user_reports', count(*)::int, null, null from public.user_reports;
rollback;
