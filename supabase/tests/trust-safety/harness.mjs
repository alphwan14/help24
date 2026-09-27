// A disposable PostgreSQL 17 (the production major version) with a replica of
// the LIVE schema for every table the Trust & Safety migrations touch, and
// those migrations applied on top. See README.md.
import EmbeddedPostgres from 'embedded-postgres';
import pg from 'pg';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const migrations = path.resolve(here, '../../migrations');

export const MIGRATIONS = [
  '114_trust_safety_schema.sql',
  '115_trust_safety_actions.sql',
  '116_trust_safety_enforcement.sql',
  '117_alert_reviews_and_finance_repairs.sql',
].map((f) => path.join(migrations, f));

const PORT = Number(process.env.TS_PG_PORT ?? 54329);

export async function withDatabase(fn, { files = MIGRATIONS, applyTwice = false } = {}) {
  const dataDir = path.join(here, '.pgdata');
  const server = new EmbeddedPostgres({
    databaseDir: dataDir,
    user: 'postgres',
    password: 'postgres',
    port: PORT,
    persistent: true,
    onLog: () => {},
    onError: () => {},
  });

  if (!fs.existsSync(path.join(dataDir, 'PG_VERSION'))) await server.initialise();
  // A previous run killed mid-flight leaves a lock file behind.
  const pid = path.join(dataDir, 'postmaster.pid');
  if (fs.existsSync(pid)) fs.rmSync(pid);
  await server.start();

  try {
    const admin = new pg.Client({ host: 'localhost', port: PORT, user: 'postgres', password: 'postgres', database: 'postgres' });
    await admin.connect();
    await admin.query('DROP DATABASE IF EXISTS trust_safety WITH (FORCE)');
    // Production is UTF8; a Windows cluster defaults to WIN1252.
    await admin.query("CREATE DATABASE trust_safety WITH ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0");
    await admin.end();

    const db = new pg.Client({ host: 'localhost', port: PORT, user: 'postgres', password: 'postgres', database: 'trust_safety' });
    await db.connect();
    db.on('error', () => {});
    const notices = [];
    db.on('notice', (n) => notices.push(n.message));

    const ordered = [path.join(here, 'replica_schema.sql'), ...files, ...(applyTwice ? files : [])];
    for (const file of ordered) {
      const sql = fs.readFileSync(file, 'utf8');
      try {
        await db.query(sql);
      } catch (e) {
        const at = e.position ? ` near: ${sql.slice(Math.max(0, Number(e.position) - 120), Number(e.position) + 60)}` : '';
        throw new Error(`applying ${path.basename(file)}: ${e.message}${at}`);
      }
    }

    await fn(db, notices);
    await db.end();
  } finally {
    await server.stop();
  }
}
