import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  IMMUTABLE,
  MUTABLE,
  SNIFF,
  cacheKeyUrl,
  declaredImageType,
  resolveImage,
  sniffImageType,
  supabaseOrigin,
  upstreamUrl,
} from '../src/policy.js';
import { BYTES } from './helpers.js';

const ID = '3f2b8c1e-9a4d-4e7b-8c21-5d6e7f8a9b0c';
const UID = 'kQ9fZ2xLmN3pR7sT1uV5wY8aB0c2';
const q = (s) => new URLSearchParams(s);

// ═══ what is served ═══════════════════════════════════════════════════════════

test('the four allowlisted shapes resolve, each to its class', () => {
  const cases = [
    [`/post-images/posts/${ID}.jpg`, IMMUTABLE],
    [`/post-images/posts/${ID}.jpeg`, IMMUTABLE],
    [`/post-images/posts/${ID}.png`, IMMUTABLE],
    [`/post-images/posts/${ID}.gif`, IMMUTABLE],
    [`/post-images/posts/${ID}.webp`, IMMUTABLE],
    [`/post-images/posts/${ID.toUpperCase()}.PNG`, IMMUTABLE],
    [`/post-images/posts/${ID}.thumb.jpg`, IMMUTABLE],
    [`/post-images/avatars/${UID}.jpg`, MUTABLE],
    [`/post-images/avatars/${UID}.webp`, MUTABLE],
    [`/profiles/${UID}/avatar.jpg`, MUTABLE],
    ['/profiles/a1b2c3d4-0000-4000-8000-000000000001/avatar.jpg', MUTABLE], // an older uuid-shaped id
  ];
  for (const [path, kind] of cases) {
    const target = resolveImage(path, q(''));
    assert.ok(target, path);
    assert.equal(target.kind, kind, path);
    assert.equal(`/${target.bucket}/${target.path}`, path);
  }
});

test('raw paths with traversal, encoding, separators or controls are refused, whatever the parser did first', () => {
  const refused = [
    '',
    '/',
    'post-images/posts/x.jpg',
    `/post-images/posts/../${ID}.jpg`,
    `/post-images/posts/../../chat-attachments/${ID}.jpg`,
    `/post-images/./posts/${ID}.jpg`,
    `/post-images/posts/${ID}.jpg/..`,
    `/post-images/posts/${ID}.jpg/.`,
    `/post-images\\posts\\${ID}.jpg`,
    `/post-images/posts\\${ID}.jpg`,
    `/post-images/posts/%2e%2e/${ID}.jpg`,
    `/post-images/posts%2F${ID}.jpg`,
    `/post-images/posts/${ID}%2Ejpg`,
    `/post-images/posts%5C${ID}.jpg`,
    `/post-images//posts/${ID}.jpg`,
    `//post-images/posts/${ID}.jpg`,
    `/post-images/posts/${ID}.jpg/`,
    `/profiles/${UID}/avatar.jpg\u0000`,
    `/profiles/${UID}/avatar.jpg\n`,
    `/profiles/${UID}/avatar.jpg\r\nx-evil: 1`,
    `/profiles/${UID}/avatar.jpg?t=1`, // a query is never part of the path
    `/profiles/${UID}/avatar.jpg#x`,
    ` /profiles/${UID}/avatar.jpg`,
    `/profiles/${UID} /avatar.jpg`,
    `/profiles/${UID}/../avatar.jpg`,
    `/profiles/${'a'.repeat(300)}/avatar.jpg`,
    `/post-images/avatars/${'a'.repeat(129)}.jpg`,
  ];
  for (const path of refused) assert.equal(resolveImage(path, q('')), null, JSON.stringify(path));
});

test('names outside the allowlist are refused: private buckets, legacy and test prefixes, wrong shapes', () => {
  const refused = [
    `/chat-attachments/${ID}/${UID}/${ID}.jpg`,
    `/chat-attachments/posts/${ID}.jpg`,
    `/dispute-evidence/${ID}/${ID}.jpg`,
    `/provider-verifications/${UID}/id-front.jpg`,
    `/provider-verifications/${UID}/avatar.jpg`,
    `/support-attachments/${ID}/${ID}.png`,
    `/post-images/chat_attachments/${ID}/${ID}.jpg`,
    `/post-images/test/${ID}.jpg`,
    '/post-images/test/diagnostic.jpg',
    `/POST-IMAGES/posts/${ID}.jpg`,
    `/post-images/POSTS/${ID}.jpg`,
    `/Profiles/${UID}/avatar.jpg`,
    `/post-images/posts/${ID}`,
    `/post-images/posts/${ID}.svg`,
    `/post-images/posts/${ID}.html`,
    `/post-images/posts/${ID}.jpg.html`,
    `/post-images/posts/${ID}.thumb.png`,
    `/post-images/posts/${ID}.THUMB.JPG`,
    `/post-images/posts/${ID}.jpg/extra.jpg`,
    `/post-images/posts/sub/${ID}.jpg`,
    '/post-images/posts/not-a-uuid.jpg',
    `/post-images/posts/${ID.slice(1)}.jpg`,
    `/post-images/avatars/${UID}.svg`,
    `/post-images/avatars/${UID}/avatar.jpg`,
    `/profiles/${UID}/avatar.png`,
    `/profiles/${UID}/avatar.JPG`,
    `/profiles/${UID}/other.jpg`,
    `/profiles/${UID}`,
    `/profiles/${UID}/`,
    `/profiles/${UID}/x/avatar.jpg`,
    '/profiles/avatar.jpg',
    '/post-images',
    '/post-images/',
    '/post-images/posts',
    `/storage/v1/object/public/post-images/posts/${ID}.jpg`,
    `/avatars/${UID}.jpg`,
    `/unknown/posts/${ID}.jpg`,
  ];
  for (const path of refused) assert.equal(resolveImage(path, q('')), null, path);
});

// ═══ the query ════════════════════════════════════════════════════════════════

test('t survives only as 1 to 20 digits, and only for the mutable class', () => {
  const avatar = `/profiles/${UID}/avatar.jpg`;
  assert.equal(resolveImage(avatar, q('t=1731745200000')).t, '1731745200000');
  assert.equal(resolveImage(avatar, q('t=1&x=2')).t, '1');
  assert.equal(resolveImage(avatar, q('x=1&t=abc')).t, null);
  assert.equal(resolveImage(avatar, q('t=')).t, null);
  assert.equal(resolveImage(avatar, q('t=-1')).t, null);
  assert.equal(resolveImage(avatar, q('t=1e5')).t, null);
  assert.equal(resolveImage(avatar, q('t=1.5')).t, null);
  assert.equal(resolveImage(avatar, q(`t=${'9'.repeat(20)}`)).t, '9'.repeat(20));
  assert.equal(resolveImage(avatar, q(`t=${'9'.repeat(21)}`)).t, null);
  assert.equal(resolveImage(avatar, q('T=123')).t, null);
  assert.equal(resolveImage(avatar).t, null);
  // An immutable name cannot change, so a t there is only a way to fan out.
  assert.equal(resolveImage(`/post-images/posts/${ID}.jpg`, q('t=123')).t, null);
});

test('cache key and upstream URL are built from the validated parts only', () => {
  const avatar = resolveImage(`/profiles/${UID}/avatar.jpg`, q('x=<script>&t=42&y=1'));
  assert.equal(cacheKeyUrl(avatar), `https://img.help24.co.ke/profiles/${UID}/avatar.jpg?t=42`);
  assert.equal(upstreamUrl('https://ref.supabase.co', avatar), `https://ref.supabase.co/storage/v1/object/public/profiles/${UID}/avatar.jpg?t=42`);
  const photo = resolveImage(`/post-images/posts/${ID}.jpg`, q('t=42&utm=x'));
  assert.equal(cacheKeyUrl(photo), `https://img.help24.co.ke/post-images/posts/${ID}.jpg`);
  assert.equal(upstreamUrl('https://ref.supabase.co', photo), `https://ref.supabase.co/storage/v1/object/public/post-images/posts/${ID}.jpg`);
});

test('SUPABASE_URL must be a bare https origin', () => {
  assert.equal(supabaseOrigin('https://ref.supabase.co'), 'https://ref.supabase.co');
  assert.equal(supabaseOrigin('https://ref.supabase.co/'), 'https://ref.supabase.co');
  for (const bad of [undefined, null, '', 'ref.supabase.co', 'http://ref.supabase.co', 'https://ref.supabase.co/rest/v1', 'https://ref.supabase.co?x=1', 'https://user:pw@ref.supabase.co']) {
    assert.throws(() => supabaseOrigin(bad), Error, String(bad));
  }
});

// ═══ content types ════════════════════════════════════════════════════════════

test('declared types: images pass (normalised), octet-stream and none are sniffed, everything else is refused', () => {
  assert.equal(declaredImageType('image/jpeg'), 'image/jpeg');
  assert.equal(declaredImageType('image/jpg'), 'image/jpeg');
  assert.equal(declaredImageType('IMAGE/PNG; charset=binary'), 'image/png');
  assert.equal(declaredImageType('image/gif'), 'image/gif');
  assert.equal(declaredImageType(' image/webp '), 'image/webp');
  assert.equal(declaredImageType(null), SNIFF);
  assert.equal(declaredImageType(''), SNIFF);
  assert.equal(declaredImageType('application/octet-stream'), SNIFF);
  for (const bad of ['text/html', 'text/html; charset=utf-8', 'image/svg+xml', 'application/xml', 'text/plain', 'application/json', 'image/x-icon', 'image/avif', 'image/jpeg2', 'application/pdf']) {
    assert.equal(declaredImageType(bad), null, bad);
  }
});

test('sniffing recognises exactly JPEG, PNG, GIF87a/89a and WEBP', () => {
  assert.equal(sniffImageType(Uint8Array.from(BYTES.jpg)), 'image/jpeg');
  assert.equal(sniffImageType(Uint8Array.from(BYTES.png)), 'image/png');
  assert.equal(sniffImageType(Uint8Array.from(BYTES.gif)), 'image/gif');
  assert.equal(sniffImageType(new TextEncoder().encode('GIF87a....')), 'image/gif');
  assert.equal(sniffImageType(Uint8Array.from(BYTES.webp)), 'image/webp');
  assert.equal(sniffImageType(new TextEncoder().encode('GIF88a....')), null);
  assert.equal(sniffImageType(new TextEncoder().encode('RIFF....WAVE')), null);
  assert.equal(sniffImageType(Uint8Array.from(BYTES.html)), null);
  assert.equal(sniffImageType(Uint8Array.from(BYTES.svg)), null);
  assert.equal(sniffImageType(Uint8Array.from([0xff, 0xd8])), null);
  assert.equal(sniffImageType(new Uint8Array(0)), null);
});
