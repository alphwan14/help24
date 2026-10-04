// Load the server credentials the local tools need from backend/.env, the one
// place they already live on this machine. Values are returned, never printed,
// and never written anywhere else — no .dev.vars copy is made.

import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(here, '../../../..');
const BACKEND = resolve(REPO_ROOT, 'backend');

/** dotenv from the backend's own install — FIREBASE_PRIVATE_KEY is multi-line,
 *  which a hand-rolled splitter gets wrong. */
export function loadBackendEnv(path = resolve(BACKEND, '.env')) {
  if (!existsSync(path)) throw new Error(`no env file at ${path}`);
  const require = createRequire(resolve(BACKEND, 'package.json'));
  const dotenv = require('dotenv');
  return dotenv.parse(readFileSync(path));
}

export function requireFrom(pkg) {
  return createRequire(resolve(BACKEND, 'package.json'))(pkg);
}

/** The Firebase project's public web API key, read from the app's own config. */
export function firebaseWebApiKey() {
  const source = readFileSync(resolve(REPO_ROOT, 'mobile-app/lib/firebase_options.dart'), 'utf8');
  const web = /static const FirebaseOptions web = FirebaseOptions\(([\s\S]*?)\);/.exec(source);
  const key = web && /apiKey: '([^']+)'/.exec(web[1]);
  if (!key) throw new Error('web apiKey not found in firebase_options.dart');
  return key[1];
}

export function need(env, ...names) {
  const missing = names.filter((n) => !env[n]);
  if (missing.length) throw new Error(`missing: ${missing.join(', ')}`);
}
