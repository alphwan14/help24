import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSupabase, UpstreamError } from '../src/supabase.js';

function recorder(response = () => new Response('[]', { status: 200 })) {
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url: String(url), init, headers: new Headers(init.headers) });
    return response(url, init);
  };
  return { calls, fetchImpl };
}

const URL_ = 'https://ref.supabase.co';
const SECRET = 'sb_secret_abcdefghijklmnopqrstuvwxyz';
const JWT = 'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.c2lnbmF0dXJl';

test('a new-style secret key is sent as apikey only; a legacy JWT as both', async () => {
  const a = recorder();
  await createSupabase({ url: URL_, serviceKey: SECRET, fetchImpl: a.fetchImpl }).chatMembers('0a0a0a0a-0000-4000-8000-000000000001');
  assert.equal(a.calls[0].headers.get('apikey'), SECRET);
  assert.equal(a.calls[0].headers.get('authorization'), null);

  const b = recorder();
  await createSupabase({ url: URL_, serviceKey: JWT, fetchImpl: b.fetchImpl }).chatMembers('0a0a0a0a-0000-4000-8000-000000000001');
  assert.equal(b.calls[0].headers.get('authorization'), `Bearer ${JWT}`);
});

test('ids that are not uuids never reach PostgREST', async () => {
  const r = recorder();
  const sb = createSupabase({ url: URL_, serviceKey: SECRET, fetchImpl: r.fetchImpl });
  for (const bad of ['1 or 1=1', 'x&select=*', '../chats', '', null]) {
    assert.equal(await sb.message(bad), null);
    assert.equal(await sb.chatMembers(bad), null);
  }
  assert.equal(r.calls.length, 0);
});

test('object access is limited to two buckets and canonical keys', async () => {
  const r = recorder(() => new Response('ok'));
  const sb = createSupabase({ url: URL_, serviceKey: SECRET, fetchImpl: r.fetchImpl });
  for (const [bucket, key] of [
    ['dispute-evidence', 'reports/u/x.jpg'],
    ['profiles', 'u/avatar.jpg'],
    ['chat-attachments', '../post-images/x.jpg'],
    ['chat-attachments', 'a/../b.jpg'],
    ['chat-attachments', 'a//b.jpg'],
    ['chat-attachments', 'a/b'],
    ['chat-attachments', 'a/b.jpg?x=1'],
    ['post-images', 'chat_attachments/a b/c.jpg'],
  ]) {
    await assert.rejects(sb.getObject(bucket, key), UpstreamError, `${bucket}/${key}`);
    await assert.rejects(sb.putObject(bucket, key, new Uint8Array(1), 'image/jpeg'), UpstreamError, `${bucket}/${key}`);
  }
  assert.equal(r.calls.length, 0);
  await sb.getObject('chat-attachments', '0a0a/1b1b.jpg', { range: 'bytes=0-1' });
  assert.equal(r.calls[0].url, `${URL_}/storage/v1/object/authenticated/chat-attachments/0a0a/1b1b.jpg`);
  assert.equal(r.calls[0].headers.get('range'), 'bytes=0-1');
});

test('putObject: stored, already exists (either duplicate shape), or an error', async () => {
  const answers = [
    () => new Response('{"Key":"x"}', { status: 200 }),
    () => new Response('{"statusCode":"409","error":"Duplicate","message":"The resource already exists"}', { status: 400 }),
    () => new Response('{"error":"Duplicate"}', { status: 409 }),
    () => new Response('{"statusCode":"403","error":"Unauthorized"}', { status: 400 }),
  ];
  let i = 0;
  const r = recorder(() => answers[i++]());
  const sb = createSupabase({ url: URL_, serviceKey: SECRET, fetchImpl: r.fetchImpl });
  const put = () => sb.putObject('chat-attachments', 'a/b.jpg', new Uint8Array([1]), 'image/jpeg');
  assert.equal(await put(), 'stored');
  assert.equal(await put(), 'exists');
  assert.equal(await put(), 'exists');
  await assert.rejects(put(), UpstreamError);
  for (const c of r.calls) assert.equal(c.headers.get('x-upsert'), 'false');
});

test('REST failures become UpstreamError without the upstream body', async () => {
  const r = recorder(() => new Response('{"message":"secret internal detail"}', { status: 500 }));
  const sb = createSupabase({ url: URL_, serviceKey: SECRET, fetchImpl: r.fetchImpl });
  await assert.rejects(sb.message('0a0a0a0a-0000-4000-8000-000000000001'), (e) => e instanceof UpstreamError && !e.message.includes('secret'));
  const down = createSupabase({ url: URL_, serviceKey: SECRET, fetchImpl: async () => { throw new TypeError('fetch failed'); } });
  await assert.rejects(down.chatMembers('0a0a0a0a-0000-4000-8000-000000000001'), UpstreamError);
});
