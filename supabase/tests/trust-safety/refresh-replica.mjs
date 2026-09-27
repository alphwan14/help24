// Regenerates replica_schema.sql from the LIVE catalog.
//
//   node refresh-replica.mjs
//
// Needs the Supabase CLI linked to the project (supabase/.temp/project-ref) and
// logged in. Every query runs inside BEGIN TRANSACTION READ ONLY ... ROLLBACK,
// so Postgres itself refuses any write — this is catalog introspection only,
// which the production-write rule pre-authorises.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../../..');

const TABLES = [
  'users', 'posts', 'post_images', 'applications', 'chats', 'chat_messages',
  'user_reports', 'admin_users', 'notifications', 'transactions', 'escrow',
  'job_completions', 'disputes', 'dispute_decisions', 'reviews',
  'provider_reputation', 'saved_items', 'fcm_tokens', 'post_engagement',
  'user_auth_identities', 'categories',
];
const list = TABLES.map((t) => `'${t}'`).join(',');

const QUERIES = {
  tables: `select 'CREATE TABLE IF NOT EXISTS public.' || quote_ident(c.relname) || E' (\\n' ||
     string_agg('  ' || quote_ident(a.attname) || ' ' || format_type(a.atttypid, a.atttypmod) ||
       case when a.attnotnull then ' NOT NULL' else '' end ||
       coalesce(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), ''), E',\\n' order by a.attnum) || E'\\n);' as ddl
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    join pg_attribute a on a.attrelid=c.oid and a.attnum>0 and not a.attisdropped
    left join pg_attrdef d on d.adrelid=c.oid and d.adnum=a.attnum
    where n.nspname='public' and c.relkind='r' and c.relname in (${list})
    group by c.relname order by c.relname`,
  constraints: `select 'ALTER TABLE public.' || quote_ident(c.relname) || ' ADD CONSTRAINT ' || quote_ident(con.conname) || ' ' || pg_get_constraintdef(con.oid) || ';' as ddl
    from pg_constraint con join pg_class c on c.oid=con.conrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname in (${list}) and con.contype in ('p','u','c','f','x')
    order by case con.contype when 'p' then 0 when 'u' then 1 when 'c' then 2 when 'x' then 3 else 4 end, c.relname, con.conname`,
  indexes: `select i.indexdef || ';' as ddl from pg_indexes i
    where i.schemaname='public' and i.tablename in (${list})
    and not exists (select 1 from pg_constraint con where con.conname = i.indexname)
    order by i.tablename, i.indexname`,
  trigfns: `select distinct pg_get_functiondef(p.oid) || ';' as ddl from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace join pg_proc p on p.oid=t.tgfoid
    where n.nspname='public' and not t.tgisinternal and c.relname in (${list})`,
  triggers: `select pg_get_triggerdef(t.oid) || ';' as ddl from pg_trigger t join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and not t.tgisinternal and c.relname in (${list}) order by c.relname, t.tgname`,
  rls: `select format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', c.relname) as ddl from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and c.relrowsecurity and c.relname in (${list}) order by 1`,
  policies: `select format('CREATE POLICY %I ON public.%I AS %s FOR %s TO %s%s%s;', policyname, tablename, permissive, cmd,
      array_to_string(roles, ', '), coalesce(' USING (' || qual || ')', ''), coalesce(' WITH CHECK (' || with_check || ')', '')) as ddl
    from pg_policies where schemaname='public' and tablename in (${list}) order by tablename, policyname`,
  grants: `select format('GRANT %s ON public.%I TO %I;', string_agg(privilege_type, ', ' order by privilege_type), table_name, grantee) as ddl
    from information_schema.role_table_grants where table_schema='public' and table_name in (${list})
    and grantee in ('anon','authenticated','service_role') group by table_name, grantee order by table_name, grantee`,
};

// The SQL goes through a file (`db query -f`), never the command line: on
// Windows npx.cmd runs under cmd.exe, which mangles a multi-line argument
// ("The syntax of the command is incorrect").
function readOnly(sql) {
  const file = path.join(os.tmpdir(), `help24-replica-${process.pid}.sql`);
  fs.writeFileSync(file, `begin transaction read only;\n${sql};\nrollback;\n`);
  try {
    const out = execFileSync(
      process.platform === 'win32' ? 'npx.cmd' : 'npx',
      ['--yes', 'supabase', 'db', 'query', '--linked', '-f', file],
      { cwd: repoRoot, encoding: 'utf8', shell: process.platform === 'win32', maxBuffer: 64 * 1024 * 1024 },
    );
    const json = JSON.parse(out.slice(out.indexOf('{')));
    return json.rows.map((r) => r.ddl);
  } finally {
    fs.rmSync(file, { force: true });
  }
}

const part = {};
for (const [name, sql] of Object.entries(QUERIES)) {
  part[name] = readOnly(sql);
  console.log(`${name}: ${part[name].length}`);
}

const inSet = new Set(TABLES);
const constraints = part.constraints.filter((s) => {
  const m = /REFERENCES\s+([a-z_."]+)\s*\(/i.exec(s);
  return !m || inSet.has(m[1].replace(/^public\./, '').replace(/"/g, ''));
});

const header = fs.readFileSync(path.join(here, 'replica_schema.sql'), 'utf8').split('-- ── Tables ──')[0]
  .replace(/on \d{4}-\d{2}-\d{2} by/, `on ${new Date().toISOString().slice(0, 10)} by`);

fs.writeFileSync(path.join(here, 'replica_schema.sql'), [
  header.trimEnd(),
  '-- ── Tables ──', part.tables.join('\n\n'),
  '-- ── Constraints ──', constraints.join('\n\n'),
  '-- ── Indexes ──', part.indexes.join('\n\n'),
  '-- ── Trigger functions ──', part.trigfns.join('\n\n'),
  '-- ── Triggers ──', part.triggers.join('\n\n'),
  '-- ── RLS ──', part.rls.join('\n\n'),
  '-- ── Policies ──', part.policies.join('\n\n'),
  '-- ── Grants (live) ──', part.grants.join('\n\n'),
].join('\n\n') + '\n');

console.log('replica_schema.sql refreshed');
