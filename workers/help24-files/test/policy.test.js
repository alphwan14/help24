import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  bytesMatchType,
  contentDisposition,
  decide,
  extForContentType,
  filenameFor,
  objectForMessage,
  participantsOf,
  privateRef,
  safeRange,
  sanitizeFilename,
} from '../src/policy.js';
import { BYTES } from './helpers.js';

const SB = 'https://ref.supabase.co';
const CHAT = '0a0a0a0a-0000-4000-8000-000000000001';
const OTHER_CHAT = '0b0b0b0b-0000-4000-8000-000000000002';
const MSG = '1a1a1a1a-0000-4000-8000-000000000001';
const OTHER_MSG = '1b1b1b1b-0000-4000-8000-000000000002';
const SENDER = 'k4DZSMsenderUid0000000000001';
const row = (attachment_url, extra = {}) => ({ id: MSG, chat_id: CHAT, sender_id: SENDER, type: 'image', content: 'Image', attachment_url, ...extra });

test('a private reference is honoured only for its own chat and message', () => {
  assert.deepEqual(objectForMessage(row(privateRef(CHAT, MSG, 'jpg')), SB), {
    bucket: 'chat-attachments',
    key: `${CHAT}/${SENDER}/${MSG}.jpg`,
    ext: 'jpg',
    legacy: false,
  });
  assert.equal(objectForMessage(row(`chat-attachments/${OTHER_CHAT}/${MSG}.jpg`), SB), null);
  assert.equal(objectForMessage(row(`chat-attachments/${CHAT}/${OTHER_MSG}.jpg`), SB), null);
  assert.equal(objectForMessage(row(`post-images/${CHAT}/${MSG}.jpg`), SB), null);
  assert.equal(objectForMessage(row(`chat-attachments/${CHAT}/${MSG}.html`), SB), null);
  assert.equal(objectForMessage(row(`chat-attachments/${CHAT}/../${OTHER_CHAT}/${MSG}.jpg`), SB), null);
  assert.equal(objectForMessage(row(`/chat-attachments/${CHAT}/${MSG}.jpg`), SB), null);
  assert.equal(objectForMessage(row(`chat-attachments/${CHAT}/${MSG}.jpg?x=1`), SB), null);
});

test("the file's type must match the message's type", () => {
  assert.equal(objectForMessage(row(privateRef(CHAT, MSG, 'pdf')), SB), null, 'a PDF is not an image message');
  assert.equal(objectForMessage(row(privateRef(CHAT, MSG, 'jpg'), { type: 'file' }), SB), null);
  assert.ok(objectForMessage(row(privateRef(CHAT, MSG, 'pdf'), { type: 'file' }), SB));
  assert.equal(objectForMessage(row(privateRef(CHAT, MSG, 'jpg'), { type: 'text' }), SB), null);
  assert.equal(objectForMessage(row(privateRef(CHAT, MSG, 'jpg'), { type: 'location' }), SB), null);
});

test('a legacy public URL is honoured only inside the row’s own chat folder, on our project', () => {
  const legacy = (folder, name = 'abc-123', ext = 'jpg', host = SB) =>
    `${host}/storage/v1/object/public/post-images/chat_attachments/${folder}/${name}.${ext}`;
  assert.deepEqual(objectForMessage(row(legacy(CHAT)), SB), {
    bucket: 'post-images',
    key: `chat_attachments/${CHAT}/abc-123.jpg`,
    ext: 'jpg',
    legacy: true,
  });
  assert.equal(objectForMessage(row(legacy(CHAT, 'x', 'jpeg')), SB).ext, 'jpg', 'jpeg normalises to jpg');
  assert.equal(objectForMessage(row(legacy(OTHER_CHAT)), SB), null);
  assert.equal(objectForMessage(row(legacy(CHAT, 'abc', 'jpg', 'https://evil.supabase.co')), SB), null);
  assert.equal(objectForMessage(row(legacy(CHAT, '../posts/x')), SB), null);
  assert.equal(objectForMessage(row(legacy(CHAT, 'a.b')), SB), null);
  assert.equal(objectForMessage(row(`${SB}/storage/v1/object/public/post-images/posts/${CHAT}/x.jpg`), SB), null);
  assert.equal(objectForMessage(row(`${SB}/storage/v1/object/sign/post-images/chat_attachments/${CHAT}/x.jpg`), SB), null);
});

test('rows that are not attachments serve nothing', () => {
  for (const bad of [null, undefined, '', 42, 'x'.repeat(700)]) {
    assert.equal(objectForMessage(row(bad), SB), null);
  }
  assert.equal(objectForMessage({ ...row(privateRef(CHAT, MSG, 'jpg')), id: 'not-a-uuid' }, SB), null);
  assert.equal(objectForMessage({ ...row(privateRef(CHAT, MSG, 'jpg')), chat_id: null }, SB), null);
  assert.equal(objectForMessage(null, SB), null);
});

test('decide: outsiders always get not_found, participants see gone for deleted', () => {
  const ok = row(privateRef(CHAT, MSG, 'jpg'));
  const deleted = { ...ok, deleted_for_everyone: true };
  assert.equal(decide(null, true, SB).status, 'not_found');
  assert.equal(decide(ok, false, SB).status, 'not_found');
  assert.equal(decide(deleted, false, SB).status, 'not_found');
  assert.equal(decide(deleted, true, SB).status, 'gone');
  assert.equal(decide(ok, true, SB).status, 'ok');
});

test('participantsOf reads the embedded chat in either shape', () => {
  assert.deepEqual(participantsOf({ chats: { user1: 'a', user2: 'b' } }), ['a', 'b']);
  assert.deepEqual(participantsOf({ chats: [{ user1: 'a', user2: 'b' }] }), ['a', 'b']);
  assert.deepEqual(participantsOf({ chats: null }), []);
  assert.deepEqual(participantsOf({ chats: { user1: '', user2: 5 } }), []);
  assert.deepEqual(participantsOf(null), []);
});

test('extForContentType allows exactly the chat attachment types', () => {
  assert.equal(extForContentType('image/jpeg'), 'jpg');
  assert.equal(extForContentType('IMAGE/PNG; charset=binary'), 'png');
  assert.equal(extForContentType('application/pdf'), 'pdf');
  assert.equal(extForContentType('application/msword'), 'doc');
  assert.equal(extForContentType('application/vnd.openxmlformats-officedocument.wordprocessingml.document'), 'docx');
  for (const no of ['text/html', 'image/svg+xml', 'application/octet-stream', 'video/mp4', '', null, undefined]) {
    assert.equal(extForContentType(no), null, String(no));
  }
});

test('magic bytes: each type must start like that type', () => {
  assert.ok(bytesMatchType('jpg', Uint8Array.from(BYTES.jpg)));
  assert.ok(bytesMatchType('png', Uint8Array.from(BYTES.png)));
  assert.ok(bytesMatchType('pdf', Uint8Array.from(BYTES.pdf)));
  assert.ok(bytesMatchType('docx', Uint8Array.from(BYTES.docx)));
  assert.ok(!bytesMatchType('jpg', Uint8Array.from(BYTES.html)));
  assert.ok(!bytesMatchType('pdf', Uint8Array.from(BYTES.html)));
  assert.ok(!bytesMatchType('png', Uint8Array.from(BYTES.jpg)));
  assert.ok(!bytesMatchType('exe', Uint8Array.from(BYTES.jpg)));
  assert.ok(!bytesMatchType('jpg', new Uint8Array(0)));
});

test('file names: documents keep theirs, photos get a readable one, nothing unsafe survives', () => {
  assert.equal(filenameFor({ type: 'file', content: 'Invoice March.pdf', id: MSG }, 'pdf'), 'Invoice March.pdf');
  assert.equal(filenameFor({ type: 'file', content: 'Invoice', id: MSG }, 'pdf'), 'Invoice.pdf');
  assert.equal(filenameFor({ type: 'file', content: 'File', id: MSG }, 'docx'), 'help24-document.docx');
  assert.equal(filenameFor({ type: 'file', content: '', id: MSG }, 'pdf'), 'help24-document.pdf');
  assert.equal(filenameFor({ type: 'file', content: '../../etc/passwd', id: MSG }, 'pdf'), 'passwd.pdf');
  assert.equal(filenameFor({ type: 'image', content: 'my caption', id: MSG }, 'jpg'), 'help24-photo-1a1a1a1a.jpg');
  assert.equal(sanitizeFilename('a\r\nb"c<d>e:f|g?h*i;j.pdf'), 'a bcdefghij.pdf');
  assert.equal(sanitizeFilename('...hidden.pdf'), 'hidden.pdf');
  const long = sanitizeFilename(`${'x'.repeat(300)}.pdf`);
  assert.equal(long.length, 120);
  assert.ok(long.endsWith('.pdf'));
});

test('Content-Disposition has an ASCII fallback and a UTF-8 name', () => {
  assert.equal(contentDisposition('Mkataba wa kazi — Juni.pdf', true),
    `inline; filename="Mkataba wa kazi _ Juni.pdf"; filename*=UTF-8''Mkataba%20wa%20kazi%20%E2%80%94%20Juni.pdf`);
  assert.equal(contentDisposition("it's.docx", false), `attachment; filename="it's.docx"; filename*=UTF-8''it%27s.docx`);
});

test('safeRange forwards one plain byte range and nothing else', () => {
  assert.equal(safeRange('bytes=0-99'), 'bytes=0-99');
  assert.equal(safeRange('bytes=100-'), 'bytes=100-');
  assert.equal(safeRange('bytes=-500'), 'bytes=-500');
  for (const no of ['bytes=-', 'bytes=0-1,4-5', 'items=0-1', 'bytes=0-1\r\nx: y', 'bytes=1234567890123-', null, '']) {
    assert.equal(safeRange(no), null, String(no));
  }
});

test("a private object is read from its SENDER's folder; a row with no usable sender serves nothing", () => {
  const ref = privateRef(CHAT, MSG, 'jpg');
  assert.equal(objectForMessage(row(ref, { sender_id: 'someone_else' }), SB).key, `${CHAT}/someone_else/${MSG}.jpg`);
  for (const bad of [null, '', '../x', 'a/b', 'a b', 'x'.repeat(129)]) {
    assert.equal(objectForMessage(row(ref, { sender_id: bad }), SB), null, String(bad));
  }
});
