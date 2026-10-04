// Move existing chat attachments off the PUBLIC post-images bucket into the
// private chat-attachments bucket — copy, verify, then repoint the message.
// The rules live in chat-attachment-migration.mjs (tested in ./test/); this
// file only connects them to the real project.
//
//   node scripts/storage/migrate-chat-attachments.mjs
//       DRY RUN (default). Reads everything, writes nothing.
//
//   node scripts/storage/migrate-chat-attachments.mjs --apply
//       For every message still on a public URL: download, upload to
//       chat-attachments/<chat>/<sender>/<message>.<ext> (never overwriting),
//       read back and compare SHA-256, record the mapping in the manifest,
//       then update the row — conditionally, WHERE id = … AND attachment_url =
//       <the old URL>. Deletes nothing.
//
//   node scripts/storage/migrate-chat-attachments.mjs --verify
//       Read-only: every attachment row names its own private object, it
//       exists, and every migrated public object still matches its copy.
//
//   node scripts/storage/migrate-chat-attachments.mjs --delete-legacy --confirm-delete <N> [--include-orphans]
//       IRREVERSIBLE. Deletes only public objects whose private copy is in the
//       manifest and verifies byte-identical right now — plus, with
//       --include-orphans, objects of conversations that no longer exist.
//       Refuses if anything is unmigrated, unverifiable or unaccounted for,
//       and unless N is exactly the number it is about to delete.
//
// The service key comes from backend/.env and is never printed. Reports and
// the manifest (which --delete-legacy depends on) are written to
// scripts/storage/reports/ (gitignored).

import { createRequire } from 'node:module';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './chat-attachment-migration.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const args = process.argv.slice(2);
const has = (flag) => args.includes(flag);
const valueOf = (flag) => (args.indexOf(flag) >= 0 ? args[args.indexOf(flag) + 1] : undefined);
const mode = has('--apply') ? 'apply' : has('--verify') ? 'verify' : has('--delete-legacy') ? 'delete-legacy' : 'dry-run';

const dotenv = createRequire(resolve(root, 'backend/package.json'))('dotenv');
const env = dotenv.parse(readFileSync(resolve(root, 'backend/.env')));
const SB = String(env.SUPABASE_URL ?? '').replace(/\/+$/, '');
const KEY = env.SUPABASE_SERVICE_ROLE_KEY;
if (!SB || !KEY) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set in backend/.env');
// A new-style secret key is only accepted as `apikey`; a legacy JWT goes in both.
const AUTH = { apikey: KEY, ...(KEY.startsWith('eyJ') ? { authorization: `Bearer ${KEY}` } : {}) };
const enc = (key) => key.split('/').map(encodeURIComponent).join('/');

const reports = resolve(here, 'reports');
mkdirSync(reports, { recursive: true });
const manifestPath = resolve(reports, 'chat-attachments-manifest.json');

async function rest(path, init = {}) {
  const res = await fetch(`${SB}/rest/v1/${path}`, { ...init, headers: { ...AUTH, accept: 'application/json', ...(init.headers ?? {}) } });
  const text = await res.text();
  if (!res.ok) throw new Error(`REST ${init.method ?? 'GET'} ${path.split('?')[0]} → HTTP ${res.status}`);
  return text ? JSON.parse(text) : null;
}

async function paged(path, size = 500) {
  const out = [];
  for (let offset = 0; ; offset += size) {
    const page = await rest(`${path}&limit=${size}&offset=${offset}`);
    out.push(...page);
    if (page.length < size) return out;
  }
}

async function list(bucket, prefix) {
  const out = [];
  for (let offset = 0; ; offset += 1000) {
    const res = await fetch(`${SB}/storage/v1/object/list/${bucket}`, {
      method: 'POST',
      headers: { ...AUTH, 'content-type': 'application/json' },
      body: JSON.stringify({ prefix, limit: 1000, offset, sortBy: { column: 'name', order: 'asc' } }),
    });
    if (!res.ok) throw new Error(`list ${bucket}/${prefix} → HTTP ${res.status}`);
    const page = await res.json();
    out.push(...page);
    if (page.length < 1000) return out;
  }
}

const io = {
  rows: () =>
    paged('chat_messages?select=id,chat_id,sender_id,type,content,attachment_url,deleted_for_everyone&attachment_url=not.is.null&order=id.asc'),

  async download(bucket, key) {
    const res = await fetch(`${SB}/storage/v1/object/authenticated/${bucket}/${enc(key)}`, { headers: AUTH });
    if (res.status === 400 || res.status === 404) {
      await res.body?.cancel();
      return null;
    }
    if (!res.ok) throw new Error(`download → HTTP ${res.status}`);
    return new Uint8Array(await res.arrayBuffer());
  },

  async upload(bucket, key, bytes, contentType) {
    const res = await fetch(`${SB}/storage/v1/object/${bucket}/${enc(key)}`, {
      method: 'POST',
      headers: { ...AUTH, 'content-type': contentType, 'x-upsert': 'false' },
      body: bytes,
    });
    const text = await res.text();
    if (res.ok) return 'stored';
    let body = {};
    try {
      body = JSON.parse(text);
    } catch {
      // not JSON
    }
    if (res.status === 409 || String(body.statusCode) === '409' || body.error === 'Duplicate') return 'exists';
    throw new Error(`upload → HTTP ${res.status} ${body.error ?? ''}`.trim());
  },

  async repoint(row, ref) {
    const updated = await rest(
      `chat_messages?id=eq.${row.id}&attachment_url=eq.${encodeURIComponent(row.attachment_url)}`,
      { method: 'PATCH', headers: { 'content-type': 'application/json', prefer: 'return=representation' }, body: JSON.stringify({ attachment_url: ref }) },
    );
    return Array.isArray(updated) && updated.length === 1 && updated[0].attachment_url === ref;
  },

  async legacyObjects() {
    const out = [];
    const folders = (await list('post-images', 'chat_attachments/')).filter((e) => e.id === null);
    for (const folder of folders) {
      for (const f of (await list('post-images', `chat_attachments/${folder.name}/`)).filter((e) => e.id !== null)) {
        out.push({ key: `chat_attachments/${folder.name}/${f.name}`, size: f.metadata?.size ?? null, created_at: f.created_at });
      }
    }
    return out;
  },

  async chatExists(chatId) {
    if (!/^[0-9a-f-]{36}$/i.test(chatId)) return false;
    return (await rest(`chats?select=id&id=eq.${chatId}&limit=1`)).length === 1;
  },

  async remove(bucket, keys) {
    const res = await fetch(`${SB}/storage/v1/object/${bucket}`, {
      method: 'DELETE',
      headers: { ...AUTH, 'content-type': 'application/json' },
      body: JSON.stringify({ prefixes: keys }),
    });
    if (!res.ok) throw new Error(`delete → HTTP ${res.status}`);
    return (await res.json()).map((o) => o.name);
  },

  snapshots: () =>
    paged('user_reports?select=id,chat_id,message_id,target_id,reported_user_id,target_snapshot&target_type=eq.message&target_snapshot->>attachment_url=not.is.null&order=id.asc'),

  manifest: {
    read: async () => (existsSync(manifestPath) ? JSON.parse(readFileSync(manifestPath, 'utf8')) : []),
    write: async (entries) => writeFileSync(manifestPath, JSON.stringify(entries, null, 2)),
  },
};

const confirm = valueOf('--confirm-delete');
const report = await run({
  mode,
  io,
  supabaseUrl: SB,
  includeOrphans: has('--include-orphans'),
  confirmDelete: confirm === undefined ? undefined : Number(confirm),
  log: (line) => console.log(line),
});
// Paths in the report are shortened: ids are not needed to read it.
const shorten = (k) => k.split('/').map((s, i) => (i === 1 ? `${s.slice(0, 8)}…` : s)).join('/');
for (const list of [report.orphans, report.unaccounted]) for (const o of list) o.key = shorten(o.key);
report.deleted = report.deleted.map(shorten);

console.log(`\nSUMMARY ${JSON.stringify(report.summary)}`);
if (report.refused) console.log(report.refused);
const file = resolve(reports, `chat-attachments-${mode}-${report.at.replace(/[:.]/g, '-')}.json`);
writeFileSync(file, JSON.stringify(report, null, 2));
console.log(`report: ${file}${mode === 'apply' ? `\nmanifest: ${manifestPath}` : ''}`);
process.exit(mode !== 'dry-run' && (report.failures.length > 0 || report.refused) ? 1 : 0);
