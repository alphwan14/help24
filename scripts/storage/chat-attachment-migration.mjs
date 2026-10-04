// The logic of moving chat attachments from the public post-images bucket to
// the private chat-attachments bucket. All I/O is injected (`io`), so every
// rule here — above all, what may ever be DELETED — is tested against a fake
// storage in scripts/storage/test/.
//
// Which object a row may name is the files Worker's own rule
// (workers/help24-files/src/policy.js), imported, not copied.

import { createHash } from 'node:crypto';
import {
  LEGACY_BUCKET,
  PRIVATE_BUCKET,
  SENDER_RE,
  TYPES,
  bytesMatchType,
  objectForMessage,
  privateKey,
  privateRef,
} from '../../workers/help24-files/src/policy.js';

export const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const short = (id) => String(id).slice(0, 8);

/**
 * @param {object} p
 * @param {'dry-run'|'apply'|'verify'|'delete-legacy'} p.mode
 * @param {object} p.io             see migrate-chat-attachments.mjs for the real one
 * @param {string} p.supabaseUrl
 * @param {boolean} [p.includeOrphans]  delete-legacy: also delete public objects of chats that no longer exist
 * @param {number} [p.confirmDelete]    delete-legacy: must equal the number about to be deleted
 */
export async function run({ mode, io, supabaseUrl, includeOrphans = false, confirmDelete, now = () => new Date().toISOString(), log = () => {} }) {
  const report = { mode, at: now(), rows: [], orphans: [], unaccounted: [], snapshots: [], deleted: [], failures: [], summary: {} };
  const fail = (what) => {
    report.failures.push(what);
    log(`  ! ${what}`);
  };

  const rows = await io.rows();
  const manifest = new Map((await io.manifest.read()).map((e) => [e.message_id, e]));
  log(`${mode.toUpperCase()} — ${rows.length} messages carry an attachment reference`);

  let migrated = 0;
  for (const row of rows) {
    const entry = { id: short(row.id), chat: short(row.chat_id), type: row.type, deleted: row.deleted_for_everyone === true };
    report.rows.push(entry);
    const object = objectForMessage(row, supabaseUrl);
    if (!object || !SENDER_RE.test(String(row.sender_id ?? ''))) {
      entry.state = 'unresolvable';
      fail(`${entry.id}: its reference names no object this message may own — fix or clear it by hand`);
      continue;
    }

    if (!object.legacy) {
      entry.state = 'private';
      const bytes = await io.download(PRIVATE_BUCKET, object.key);
      const known = manifest.get(row.id);
      if (!bytes) fail(`${entry.id}: private object missing`);
      else if (known && sha256(bytes) !== known.sha256) fail(`${entry.id}: private object differs from what was migrated`);
      log(`  ${bytes ? 'DONE   ' : 'MISSING'} ${entry.id} ${row.type} already private`);
      continue;
    }

    entry.state = 'legacy';
    const target = privateKey(row.chat_id, row.sender_id, row.id, object.ext);
    const ref = privateRef(row.chat_id, row.id, object.ext);
    const source = await io.download(LEGACY_BUCKET, object.key);
    if (!source) {
      fail(`${entry.id}: the public object is gone and the row still points at it`);
      continue;
    }
    entry.size = source.length;
    entry.sha256 = sha256(source);
    if (!bytesMatchType(object.ext, source)) {
      fail(`${entry.id}: bytes are not a real .${object.ext} — not copied`);
      continue;
    }
    const existing = await io.download(PRIVATE_BUCKET, target);
    if (existing && sha256(existing) !== entry.sha256) {
      fail(`${entry.id}: a DIFFERENT object already sits at the private key — not touched`);
      continue;
    }

    if (mode !== 'apply') {
      entry.action = existing ? 'copy exists; row not yet repointed' : 'would copy, verify, repoint';
      if (mode === 'verify' || mode === 'delete-legacy') fail(`${entry.id}: not migrated yet`);
      log(`  PLAN    ${entry.id} ${row.type} ${source.length} B → ${PRIVATE_BUCKET}/${short(row.chat_id)}…/${short(row.sender_id)}…/${short(row.id)}….${object.ext}${entry.deleted ? ' [deleted message — kept for Trust & Safety]' : ''}`);
      continue;
    }

    try {
      if (!existing) await io.upload(PRIVATE_BUCKET, target, source, TYPES[object.ext].mime);
      const back = await io.download(PRIVATE_BUCKET, target);
      if (!back || sha256(back) !== entry.sha256) throw new Error('read-back does not match the source');
      // Recorded BEFORE the row moves: if the run dies after the update, the
      // old object's mapping is still known, so it can be verified and deleted.
      manifest.set(row.id, {
        message_id: row.id,
        chat_id: row.chat_id,
        sender_id: row.sender_id,
        legacy_key: object.key,
        private_key: target,
        sha256: entry.sha256,
        migrated_at: now(),
      });
      await io.manifest.write([...manifest.values()]);
      if (!(await io.repoint(row, ref))) throw new Error('row changed since it was read — not repointed');
      entry.action = 'copied, verified, repointed';
      migrated++;
      log(`  MIGRATED ${entry.id} ${row.type} ${source.length} B sha256 ${entry.sha256.slice(0, 12)}…`);
    } catch (e) {
      fail(`${entry.id}: ${e.message}`);
    }
  }

  // ── public objects: accounted for, orphaned, or unaccounted ──────────────
  const legacyInUse = new Set(
    rows.map((r) => objectForMessage(r, supabaseUrl)).filter((o) => o?.legacy).map((o) => o.key),
  );
  const byLegacyKey = new Map([...manifest.values()].map((e) => [e.legacy_key, e]));
  const verifiedCopies = [];
  for (const obj of await io.legacyObjects()) {
    if (legacyInUse.has(obj.key)) continue; // a row still points at it
    const entry = byLegacyKey.get(obj.key);
    if (entry) {
      // Re-verified NOW, never trusted from the manifest alone: both copies
      // present and byte-identical to what was migrated.
      const [src, priv] = await Promise.all([io.download(LEGACY_BUCKET, obj.key), io.download(PRIVATE_BUCKET, entry.private_key)]);
      if (src && priv && sha256(src) === entry.sha256 && sha256(priv) === entry.sha256) verifiedCopies.push(obj.key);
      else fail(`${short(entry.message_id)}: copy no longer verifies — its public object will not be deleted`);
      continue;
    }
    const chatId = obj.key.split('/')[1];
    if (await io.chatExists(chatId)) {
      report.unaccounted.push({ key: obj.key, size: obj.size, created_at: obj.created_at });
    } else {
      report.orphans.push({ key: obj.key, size: obj.size, created_at: obj.created_at });
    }
  }
  for (const o of report.orphans) log(`  ORPHAN  ${short(o.key.split('/')[1])}…/${o.key.split('/')[2]} ${o.size ?? '?'} B — its conversation no longer exists`);
  for (const o of report.unaccounted) {
    log(`  UNACCOUNTED ${short(o.key.split('/')[1])}…/${o.key.split('/')[2]} — in a live conversation, referenced by no message`);
  }
  if (mode === 'delete-legacy' && report.unaccounted.length) {
    fail(`${report.unaccounted.length} public object(s) in live conversations are referenced by no message and were never migrated — review by hand`);
  }

  // ── Trust & Safety snapshots ─────────────────────────────────────────────
  for (const r of await io.snapshots()) {
    const snap = r.target_snapshot ?? {};
    const sender = r.reported_user_id;
    const object = objectForMessage({ id: r.message_id ?? r.target_id, chat_id: r.chat_id, sender_id: sender, type: snap.type, attachment_url: snap.attachment_url }, supabaseUrl);
    const key = object && SENDER_RE.test(String(sender ?? '')) ? privateKey(r.chat_id, sender, r.message_id ?? r.target_id, object.ext) : null;
    const present = key ? Boolean(await io.download(PRIVATE_BUCKET, key)) : false;
    report.snapshots.push({ report: short(r.id), resolves: Boolean(key), private_copy: present });
  }

  // ── deleting public objects (only in delete-legacy) ──────────────────────
  if (mode === 'delete-legacy') {
    const targets = [...verifiedCopies, ...(includeOrphans ? report.orphans.map((o) => o.key) : [])];
    if (report.failures.length > 0) {
      report.refused = `refused: ${report.failures.length} problem(s) above`;
    } else if (confirmDelete !== targets.length) {
      report.refused = `refused: --confirm-delete ${confirmDelete ?? '(missing)'} but ${targets.length} objects are eligible`;
    } else if (targets.length > 0) {
      report.deleted = await io.remove(LEGACY_BUCKET, targets);
    }
    log(report.refused ?? `DELETED ${report.deleted.length} public objects`);
  }

  const count = (state) => report.rows.filter((r) => r.state === state).length;
  report.summary = {
    rows: rows.length,
    private: count('private'),
    legacy: count('legacy'),
    unresolvable: count('unresolvable'),
    migrated_now: migrated,
    failures: report.failures.length,
    public_objects_with_verified_private_copy: verifiedCopies.length,
    orphans: report.orphans.length,
    unaccounted: report.unaccounted.length,
    snapshots: report.snapshots.length,
    deleted: report.deleted.length,
  };
  return report;
}
