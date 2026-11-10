import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import PostalMime from 'postal-mime';
import { buildPayload, deliver, htmlToText, isAutomated, signedBody } from '../src/mail.js';
import { copyAddresses, handleEmail } from '../src/index.js';

const headers = (h = {}) => new Headers(h);

const RAW_REPLY = [
  'From: "Mary Wanjikũ" <Mary.Wanjiku@Example.com>',
  'To: Help24 Support <support@help24.co.ke>',
  'Subject: Re: Payout not received [H24-7K3QXP]',
  'Message-ID: <reply-1@mail.example.com>',
  'In-Reply-To: <abc@help24.co.ke>',
  'References: <first@mail.example.com> <abc@help24.co.ke>',
  'Content-Type: text/plain; charset=utf-8',
  'Content-Transfer-Encoding: 8bit',
  '',
  'Still nothing, sorry.',
  '',
  'On Tue, 4 Nov 2026 at 10:02, Help24 Support <support@help24.co.ke> wrote:',
  '> We are checking.',
  '',
].join('\r\n');

const RAW_HTML_ONLY = [
  'From: someone@example.org',
  'To: info@help24.co.ke',
  'Subject: Partnership',
  'Message-ID: <html-1@example.org>',
  'Content-Type: text/html; charset=utf-8',
  '',
  '<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;team,</p><p>We would like to <b>partner</b>.</p></body></html>',
].join('\r\n');

test('a real reply is turned into the backend\'s JSON: lower-cased sender, threading ids, our recipient', async () => {
  const parsed = await PostalMime.parse(RAW_REPLY);
  const p = buildPayload({ envelopeTo: 'support@help24.co.ke', parsed, headers: headers({ 'authentication-results': 'mx.cloudflare.net; dmarc=pass' }) });
  assert.equal(p.from.address, 'mary.wanjiku@example.com');
  assert.equal(p.from.name, 'Mary Wanjikũ');
  assert.deepEqual(p.to, ['support@help24.co.ke']);
  assert.equal(p.subject, 'Re: Payout not received [H24-7K3QXP]');
  assert.equal(p.messageId, '<reply-1@mail.example.com>');
  assert.equal(p.inReplyTo, '<abc@help24.co.ke>');
  assert.deepEqual(p.references, ['<first@mail.example.com>', '<abc@help24.co.ke>']);
  assert.deepEqual(p.authResults, ['mx.cloudflare.net; dmarc=pass']);
  assert.match(p.text, /^Still nothing, sorry\./);
  assert.equal(p.automated, false);
});

test('an HTML-only email still arrives as readable text', async () => {
  const parsed = await PostalMime.parse(RAW_HTML_ONLY);
  const p = buildPayload({ envelopeTo: 'info@help24.co.ke', parsed, headers: headers() });
  assert.equal(p.text, 'Hello team,\nWe would like to partner .');
  assert.ok(!p.text.includes('color:red'));
  assert.equal(htmlToText('a<br>b &amp; c'), 'a\nb & c');
});

test('auto-replies, bounces, mailing lists and no-reply senders are marked automated', () => {
  assert.equal(isAutomated(headers({ 'auto-submitted': 'auto-replied' }), 'a@x.com'), true);
  assert.equal(isAutomated(headers({ 'auto-submitted': 'no' }), 'a@x.com'), false);
  assert.equal(isAutomated(headers({ precedence: 'bulk' }), 'a@x.com'), true);
  assert.equal(isAutomated(headers({ 'list-unsubscribe': '<mailto:x>' }), 'a@x.com'), true);
  assert.equal(isAutomated(headers({ 'content-type': 'multipart/report; report-type=delivery-status' }), 'a@x.com'), true);
  assert.equal(isAutomated(headers(), 'MAILER-DAEMON@mx.example.com'), true);
  assert.equal(isAutomated(headers(), 'noreply@bank.example'), true);
  assert.equal(isAutomated(headers(), 'mary@example.com'), false);
});

test('the signature is exactly what the backend checks, and the payload round-trips UTF-8', async () => {
  const json = { from: { address: 'a@example.com', name: 'Wanjikũ Mwangi' }, text: 'Habari — asante 🙏' };
  const body = await signedBody('k3y', json, 1_800_000_000);
  // backend/src/support/support-rules.ts signInbound
  const expected = createHmac('sha256', 'k3y').update(`1800000000.${body.payload}`).digest('hex');
  assert.equal(body.signature, expected);
  assert.deepEqual(JSON.parse(Buffer.from(body.payload, 'base64').toString('utf8')), json);
});

test('delivery retries what a retry can fix, and stops on a request the backend refuses', async () => {
  const sleep = async () => {};
  const statuses = [503, 502, 200];
  let calls = 0;
  const flaky = async () => ({ ok: statuses[calls] < 300, status: statuses[calls++] });
  assert.deepEqual(await deliver({ url: 'u', secret: 's', json: {}, fetchImpl: flaky, sleep }), { ok: true, status: 200, attempts: 3 });

  calls = 0;
  const refused = async () => (calls++, { ok: false, status: 401 });
  assert.deepEqual(await deliver({ url: 'u', secret: 's', json: {}, fetchImpl: refused, sleep }), { ok: false, status: 401, attempts: 1 });
  assert.equal(calls, 1);

  const down = async () => { throw new Error('ECONNRESET'); };
  assert.deepEqual(await deliver({ url: 'u', secret: 's', json: {}, fetchImpl: down, sleep }), { ok: false, status: 0, attempts: 3 });
});

/** An Email Routing message, as the Worker runtime hands it over. */
function fakeMessage(raw, to = 'support@help24.co.ke') {
  const calls = { forward: [], reject: [] };
  return {
    calls,
    message: {
      to,
      from: 'mary.wanjiku@example.com',
      raw: new Response(raw).body,
      rawSize: raw.length,
      headers: new Headers({ 'authentication-results': 'mx; dmarc=pass' }),
      forward: async (addr) => { calls.forward.push(addr); },
      setReject: (reason) => { calls.reject.push(reason); },
    },
  };
}

const ENV = { SUPPORT_INBOUND_URL: 'https://api.example/support/inbound-email', SUPPORT_INBOUND_SECRET: 'k3y' };

test('the handler copies to the team inbox first, then hands the email to the Inbox', async () => {
  const { message, calls } = fakeMessage(RAW_REPLY);
  let delivered = null;
  await handleEmail(message, { ...ENV, FORWARD_TO: 'team@example.com' }, {
    deliverImpl: async (args) => ((delivered = args), { ok: true, status: 200, attempts: 1 }),
  });
  assert.deepEqual(calls.forward, ['team@example.com']);
  assert.deepEqual(calls.reject, []);
  assert.equal(delivered.url, ENV.SUPPORT_INBOUND_URL);
  assert.equal(delivered.json.from.address, 'mary.wanjiku@example.com');
});

test('settings pasted with stray spaces or a newline still work', async () => {
  const { message, calls } = fakeMessage(RAW_REPLY);
  let delivered = null;
  await handleEmail(
    message,
    {
      SUPPORT_INBOUND_URL: ` ${ENV.SUPPORT_INBOUND_URL}\n`,
      SUPPORT_INBOUND_SECRET: `  ${ENV.SUPPORT_INBOUND_SECRET}\r\n`,
      FORWARD_TO: ' team@example.com\n',
    },
    { deliverImpl: async (args) => ((delivered = args), { ok: true, status: 200, attempts: 1 }) },
  );
  assert.deepEqual(calls.forward, ['team@example.com']);
  assert.equal(delivered.url, ENV.SUPPORT_INBOUND_URL);
  assert.equal(delivered.secret, ENV.SUPPORT_INBOUND_SECRET); // signs with the same bytes the backend trims to
  assert.deepEqual(calls.reject, []);

  // Whitespace alone is no secret: refused, not signed with an empty key.
  const blank = fakeMessage(RAW_REPLY);
  await handleEmail(blank.message, { ...ENV, SUPPORT_INBOUND_SECRET: '  \n' }, { deliverImpl: async () => assert.fail('must not deliver') });
  assert.equal(blank.calls.reject.length, 1);
});

test('copies go to every address in FORWARD_TO, and one failing does not stop the rest', async () => {
  assert.deepEqual(copyAddresses(' a@x.com, b@y.com;A@X.com  c@z.com\n'), ['a@x.com', 'b@y.com', 'c@z.com']);
  assert.deepEqual(copyAddresses(''), []);
  assert.deepEqual(copyAddresses(undefined), []);
  assert.deepEqual(copyAddresses('not-an-address, ok@x.com'), ['ok@x.com']);
  assert.equal(copyAddresses('1@x.co 2@x.co 3@x.co 4@x.co 5@x.co 6@x.co').length, 5);

  const { message, calls } = fakeMessage(RAW_REPLY);
  const tried = [];
  message.forward = async (addr) => {
    tried.push(addr);
    if (addr === 'unverified@example.com') throw new Error('destination address not verified');
    calls.forward.push(addr);
  };
  const failing = async () => ({ ok: false, status: 503, attempts: 3 });
  await handleEmail(message, { ...ENV, FORWARD_TO: 'unverified@example.com, team@example.com' }, { deliverImpl: failing });
  assert.deepEqual(tried, ['unverified@example.com', 'team@example.com']);
  assert.deepEqual(calls.forward, ['team@example.com']);
  assert.deepEqual(calls.reject, []); // one copy landed, so the email is not refused
});

test('nothing is lost silently: no copy and no Inbox means the sender is told', async () => {
  const failing = async () => ({ ok: false, status: 503, attempts: 3 });
  const noCopy = fakeMessage(RAW_REPLY);
  await handleEmail(noCopy.message, ENV, { deliverImpl: failing });
  assert.equal(noCopy.calls.reject.length, 1);

  const withCopy = fakeMessage(RAW_REPLY);
  await handleEmail(withCopy.message, { ...ENV, FORWARD_TO: 'team@example.com' }, { deliverImpl: failing });
  assert.deepEqual(withCopy.calls.reject, []); // the team inbox has it

  const notConfigured = fakeMessage(RAW_REPLY);
  await handleEmail(notConfigured.message, {}, { deliverImpl: failing });
  assert.equal(notConfigured.calls.reject.length, 1);
});
