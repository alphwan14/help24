// The chat-attachment migration against a fake storage. What matters most is
// what --delete-legacy may delete: only public objects whose private copy is
// recorded AND verifies byte-identical, plus — on request — objects of
// conversations that no longer exist. Anything else blocks it.
//
//   node --test scripts/storage/test/

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { run, sha256 } from '../chat-attachment-migration.mjs';

const SB = 'https://ref.supabase.co';
const CHAT = 'c4a541f9-0000-4000-8000-000000000001';
const LIVE_CHAT_NO_ROWS = 'c5c5c5c5-0000-4000-8000-000000000005';
const DEAD_CHAT = 'cdd48b13-0000-4000-8000-000000000002';
const SENDER = 'k4DZSMsenderUid0000000000001';
const JPG = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
const PDF = new TextEncoder().encode('%PDF-1.4 test');
const legacyUrl = (chat, name) => `${SB}/storage/v1/object/public/post-images/chat_attachments/${chat}/${name}`;
const msg = (n) => `a${n}000000-0000-4000-8000-00000000000${n}`;

function world() {
  const objects = new Map();
  const rows = [];
  const chats = new Set([CHAT, LIVE_CHAT_NO_ROWS]);
  const state = { manifest: [], removed: [] };
  const put = (bucket, key, bytes) => objects.set(`${bucket}/${key}`, Uint8Array.from(bytes));
  const io = {
    rows: async () => rows.map((r) => ({ ...r })),
    download: async (b, k) => objects.get(`${b}/${k}`) ?? null,
    upload: async (b, k, bytes) => {
      if (objects.has(`${b}/${k}`)) return 'exists';
      put(b, k, bytes);
      return 'stored';
    },
    repoint: async (row, ref) => {
      const r = rows.find((x) => x.id === row.id);
      if (!r || r.attachment_url !== row.attachment_url) return false;
      r.attachment_url = ref;
      return true;
    },
    legacyObjects: async () =>
      [...objects.keys()]
        .filter((k) => k.startsWith('post-images/chat_attachments/'))
        .map((k) => ({ key: k.slice('post-images/'.length), size: objects.get(k).length })),
    chatExists: async (id) => chats.has(id),
    remove: async (b, keys) => {
      for (const k of keys) {
        objects.delete(`${b}/${k}`);
        state.removed.push(k);
      }
      return keys;
    },
    snapshots: async () => [],
    manifest: { read: async () => state.manifest, write: async (e) => void (state.manifest = e) },
  };
  // Two migratable messages, one of them deleted for everyone.
  rows.push({ id: msg(1), chat_id: CHAT, sender_id: SENDER, type: 'image', attachment_url: legacyUrl(CHAT, 'old-1.jpg'), deleted_for_everyone: false });
  put('post-images', `chat_attachments/${CHAT}/old-1.jpg`, JPG);
  rows.push({ id: msg(2), chat_id: CHAT, sender_id: SENDER, type: 'file', attachment_url: legacyUrl(CHAT, 'old-2.pdf'), deleted_for_everyone: true });
  put('post-images', `chat_attachments/${CHAT}/old-2.pdf`, PDF);
  // An orphan from a conversation that was deleted.
  put('post-images', `chat_attachments/${DEAD_CHAT}/gone.jpg`, JPG);
  const go = (mode, extra = {}) => run({ mode, io, supabaseUrl: SB, ...extra });
  return { objects, rows, chats, state, put, io, go };
}

test('a dry run changes nothing', async () => {
  const w = world();
  const before = JSON.stringify([...w.objects.keys()]) + JSON.stringify(w.rows);
  const report = await w.go('dry-run');
  assert.equal(JSON.stringify([...w.objects.keys()]) + JSON.stringify(w.rows), before);
  assert.deepEqual(w.state.manifest, []);
  assert.equal(report.summary.legacy, 2);
  assert.equal(report.summary.orphans, 1);
});

test("apply copies into the sender's folder, verifies, records, then repoints", async () => {
  const w = world();
  const report = await w.go('apply');
  assert.equal(report.summary.migrated_now, 2);
  assert.deepEqual(report.failures, []);
  assert.deepEqual([...w.objects.get(`chat-attachments/${CHAT}/${SENDER}/${msg(1)}.jpg`)], [...JPG]);
  assert.equal(w.rows[0].attachment_url, `chat-attachments/${CHAT}/${msg(1)}.jpg`);
  assert.equal(w.rows[1].attachment_url, `chat-attachments/${CHAT}/${msg(2)}.pdf`);
  assert.deepEqual(w.state.manifest.map((e) => [e.legacy_key, e.sha256]), [
    [`chat_attachments/${CHAT}/old-1.jpg`, sha256(JPG)],
    [`chat_attachments/${CHAT}/old-2.pdf`, sha256(PDF)],
  ]);
  assert.ok(w.objects.has(`post-images/chat_attachments/${CHAT}/old-1.jpg`), 'apply deletes nothing');
  assert.deepEqual((await w.go('verify')).failures, []);
});

test('apply never overwrites a different object, and never copies fake content', async () => {
  const w = world();
  w.put('chat-attachments', `${CHAT}/${SENDER}/${msg(1)}.jpg`, [0xff, 0xd8, 0xff, 9, 9]);
  w.put('post-images', `chat_attachments/${CHAT}/old-2.pdf`, new TextEncoder().encode('<html>'));
  const report = await w.go('apply');
  assert.equal(report.summary.migrated_now, 0);
  assert.equal(report.failures.length, 2);
  assert.equal(w.rows[0].attachment_url, legacyUrl(CHAT, 'old-1.jpg'));
  assert.equal(w.rows[1].attachment_url, legacyUrl(CHAT, 'old-2.pdf'));
});

test('a row edited since it was read is not repointed', async () => {
  const w = world();
  const original = w.io.repoint;
  w.io.repoint = async (row, ref) => {
    w.rows.find((r) => r.id === row.id).attachment_url = 'changed by someone';
    return original(row, ref);
  };
  const report = await w.go('apply');
  assert.equal(report.summary.migrated_now, 0);
  assert.ok(w.rows.every((r) => r.attachment_url === 'changed by someone'));
});

test('delete-legacy refuses while anything is unmigrated', async () => {
  const w = world();
  const report = await w.go('delete-legacy', { confirmDelete: 3, includeOrphans: true });
  assert.match(report.refused, /refused/);
  assert.deepEqual(w.state.removed, []);
});

test('delete-legacy deletes exactly the verified public copies — and orphans only on request', async () => {
  const w = world();
  await w.go('apply');
  const wrongCount = await w.go('delete-legacy', { confirmDelete: 3 });
  assert.match(wrongCount.refused, /2 objects are eligible/);
  assert.deepEqual(w.state.removed, []);

  const report = await w.go('delete-legacy', { confirmDelete: 2 });
  assert.equal(report.refused, undefined);
  assert.deepEqual(w.state.removed.sort(), [`chat_attachments/${CHAT}/old-1.jpg`, `chat_attachments/${CHAT}/old-2.pdf`]);
  assert.ok(w.objects.has(`post-images/chat_attachments/${DEAD_CHAT}/gone.jpg`), 'the orphan was not asked for');
  assert.ok(w.objects.has(`chat-attachments/${CHAT}/${SENDER}/${msg(1)}.jpg`));

  const orphans = await w.go('delete-legacy', { confirmDelete: 1, includeOrphans: true });
  assert.equal(orphans.refused, undefined);
  assert.deepEqual(w.state.removed.slice(-1), [`chat_attachments/${DEAD_CHAT}/gone.jpg`]);
});

test('an unmigrated object in a LIVE conversation blocks deletion entirely', async () => {
  const w = world();
  await w.go('apply');
  w.put('post-images', `chat_attachments/${LIVE_CHAT_NO_ROWS}/unknown.jpg`, JPG);
  const report = await w.go('delete-legacy', { confirmDelete: 3, includeOrphans: true });
  assert.match(report.refused, /refused/);
  assert.equal(report.unaccounted.length, 1);
  assert.deepEqual(w.state.removed, []);
});

test('a lost manifest makes migrated objects unaccounted, so nothing is deleted', async () => {
  const w = world();
  await w.go('apply');
  w.state.manifest = [];
  const report = await w.go('delete-legacy', { confirmDelete: 2 });
  assert.match(report.refused, /refused/);
  assert.equal(report.unaccounted.length, 2);
  assert.deepEqual(w.state.removed, []);
});

test('a private copy that no longer matches blocks deletion', async () => {
  const w = world();
  await w.go('apply');
  w.put('chat-attachments', `${CHAT}/${SENDER}/${msg(1)}.jpg`, [0xff, 0xd8, 0xff, 7]);
  const report = await w.go('delete-legacy', { confirmDelete: 2 });
  assert.match(report.refused, /refused/);
  assert.deepEqual(w.state.removed, []);
});

test('an unresolvable row is a failure and blocks deletion', async () => {
  const w = world();
  await w.go('apply');
  w.rows.push({ id: msg(3), chat_id: CHAT, sender_id: SENDER, type: 'image', attachment_url: 'https://evil.example/x.jpg' });
  const report = await w.go('delete-legacy', { confirmDelete: 2 });
  assert.match(report.refused, /refused/);
  assert.deepEqual(w.state.removed, []);
});

test('re-verification at delete time: a changed public object, or a missing copy whose row is gone, blocks deletion', async () => {
  const changed = world();
  await changed.go('apply');
  changed.put('post-images', `chat_attachments/${CHAT}/old-1.jpg`, [0xff, 0xd8, 0xff, 1]);
  assert.match((await changed.go('delete-legacy', { confirmDelete: 2 })).refused, /refused/);
  assert.deepEqual(changed.state.removed, []);

  const rowGone = world();
  await rowGone.go('apply');
  rowGone.rows.splice(0, 1); // the conversation was deleted after migration
  rowGone.objects.delete(`chat-attachments/${CHAT}/${SENDER}/${msg(1)}.jpg`);
  assert.match((await rowGone.go('delete-legacy', { confirmDelete: 2 })).refused, /refused/);
  assert.deepEqual(rowGone.state.removed, []);
});
