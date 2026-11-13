import {
  identityFor,
  inboundBody,
  labelFor,
  makeRef,
  normalizeSubject,
  normalizeMessageId,
  parseInbound,
  refInSubject,
  replyHtml,
  replySubject,
  replyText,
  senderVerified,
  signInbound,
  stripQuotedReply,
  threadSubject,
  verifyInbound,
} from './support-rules';

describe('support rules', () => {
  it('references are H24- plus six unambiguous characters, and a subject gives one back', () => {
    for (let i = 0; i < 200; i++) expect(makeRef()).toMatch(/^H24-[A-HJ-NP-Z2-9]{6}$/);
    expect(refInSubject('Re: Payout question [H24-7K3QXP]')).toBe('H24-7K3QXP');
    expect(refInSubject('Re: Payout question [H24-0K3QXP]')).toBeNull(); // 0 is never issued
    expect(refInSubject('No reference here')).toBeNull();
  });

  it('subjects: prefixes and our reference are ignored when comparing, kept readable for the thread', () => {
    expect(normalizeSubject('RE: Fwd: Re: Payout  question [H24-7K3QXP]')).toBe('payout question');
    expect(normalizeSubject('AW: payout question')).toBe('payout question');
    expect(threadSubject('Re: Payout question [H24-7K3QXP]')).toBe('Payout question');
    expect(threadSubject('   ')).toBe('No subject');
    expect(threadSubject('x'.repeat(300))).toHaveLength(200);
    expect(replySubject('Re: Payout question [H24-7K3QXP]', 'H24-7K3QXP')).toBe('Re: Payout question [H24-7K3QXP]');
  });

  it('info@ is General, support@ (and any other help24 address) is Support, nothing else is ours', () => {
    expect(labelFor(['info@help24.co.ke'])).toBe('general');
    expect(labelFor(['Support@Help24.co.ke'])).toBe('support');
    expect(labelFor(['support+x@help24.co.ke'])).toBe('support');
    expect(labelFor(['info@help24.co.ke', 'support@help24.co.ke'])).toBe('support');
    expect(labelFor(['hello@help24.co.ke'])).toBe('support');
    expect(labelFor(['someone@gmail.com'])).toBeNull();
    expect(labelFor(['Security@help24.co.ke'])).toBe('security');
    expect(labelFor(['support@help24.co.ke', 'security@help24.co.ke'])).toBe('security');
  });

  it('security@ is answered as Help24 Security; everything else as Help24 Support', () => {
    expect(identityFor('security')).toEqual({ from: 'Help24 Security <security@help24.co.ke>', address: 'security@help24.co.ke', signature: 'Help24 Security' });
    expect(identityFor('general')).toEqual(identityFor('support'));
    expect(identityFor('support').from).toBe('Help24 Support <support@help24.co.ke>');
    expect(replyText('Hi.', 'Help24 Security')).toBe('Hi.\n\nHelp24 Security\nhelp24.co.ke');
    expect(replyText('Hi.')).toBe('Hi.\n\nHelp24 Support\nhelp24.co.ke');
  });

  it('a reply keeps only the new text: Gmail, Outlook, "Original Message" and > quotes are cut', () => {
    expect(stripQuotedReply('Thanks, that fixed it.\n\nOn Tue, 4 Nov 2026 at 10:02, Help24 Support <support@help24.co.ke> wrote:\n> Try again now.'))
      .toBe('Thanks, that fixed it.');
    expect(stripQuotedReply('Still waiting.\n\nOn Tue, 4 Nov 2026 at 10:02, Help24 Support\n<support@help24.co.ke> wrote:\n> old'))
      .toBe('Still waiting.');
    expect(stripQuotedReply('Ok\r\n\r\nFrom: Help24 Support <support@help24.co.ke>\r\nSent: Tuesday\r\nTo: me\r\n\r\nold text'))
      .toBe('Ok');
    expect(stripQuotedReply('Yes please.\n-----Original Message-----\nold')).toBe('Yes please.');
    expect(stripQuotedReply('Done.\n\n> quoted\n> more\n')).toBe('Done.');
    // A quote in the middle, followed by new text, is not the history: keep it all.
    expect(stripQuotedReply('> you said\nI disagree')).toBe('> you said\nI disagree');
    // Nothing new would be left: keep the whole email.
    expect(stripQuotedReply('On Mon someone wrote:\n> hi')).toBe('On Mon someone wrote:\n> hi');
  });

  it('the stored body is the new text; the full email is kept only when something was cut', () => {
    expect(inboundBody('Hello')).toEqual({ body: 'Hello', full: null });
    const r = inboundBody('Thanks\n\nOn Mon, X wrote:\n> old');
    expect(r.body).toBe('Thanks');
    expect(r.full).toContain('> old');
    expect(inboundBody('   ').body).toBe('(No text in this email.)');
  });

  it('the sender is verified by DMARC, or DKIM for the From domain; unknown when there is no verdict', () => {
    expect(senderVerified(['mx.cloudflare.net; dkim=pass header.d=gmail.com; spf=pass; dmarc=pass header.from=gmail.com'], 'a@gmail.com')).toBe(true);
    expect(senderVerified(['mx; dkim=pass header.d=mail.example.org; dmarc=none'], 'a@example.org')).toBe(true);
    expect(senderVerified(['mx; dkim=pass header.d=other.com; spf=fail; dmarc=fail'], 'a@gmail.com')).toBe(false);
    expect(senderVerified([], 'a@gmail.com')).toBeNull();
  });

  it('inbound signature: right secret, fresh, unaltered; anything else is refused', () => {
    const now = 1_800_000_000;
    const payload = Buffer.from('{"x":1}').toString('base64');
    const sig = signInbound('s3cret', now, payload);
    expect(verifyInbound('s3cret', now, payload, sig, now + 10)).toBe(true);
    expect(verifyInbound('other', now, payload, sig, now)).toBe(false);
    expect(verifyInbound('s3cret', now, payload + 'A', sig, now)).toBe(false);
    expect(verifyInbound('s3cret', now, payload, sig, now + 301)).toBe(false);
    expect(verifyInbound('s3cret', now, payload, sig, now - 301)).toBe(false);
    expect(verifyInbound('s3cret', now, payload, 'zz', now)).toBe(false);
    expect(verifyInbound('', now, payload, sig, now)).toBe(false);
  });

  it('the Worker\'s JSON is checked and bounded; a missing or bad From is refused', () => {
    const e = parseInbound({
      from: { address: ' Member@Example.COM ', name: 'Mary' },
      to: ['support@help24.co.ke'],
      subject: 'Help',
      text: 'x'.repeat(70000),
      messageId: 'abc@mail.example.com',
      inReplyTo: '<def@help24.co.ke>',
      references: ['<a@x>', 'bad id with spaces', '<b@x>'],
      authResults: ['dmarc=pass'],
      attachments: 2,
      automated: false,
    });
    expect(e.from.address).toBe('member@example.com');
    expect(e.text).toHaveLength(60000);
    expect(e.messageId).toBe('<abc@mail.example.com>');
    expect(e.references).toEqual(['<a@x>', '<b@x>']);
    expect(() => parseInbound({ from: { address: 'not-an-email' } })).toThrow();
    expect(normalizeMessageId('  ')).toBeNull();
  });

  it('a staff reply is signed "Help24 Support", and its HTML escapes what the admin typed', () => {
    expect(replyText('Hello\n')).toBe('Hello\n\nHelp24 Support\nhelp24.co.ke');
    const html = replyHtml('Use <b>this</b> & that\nline two\n\nNext paragraph');
    expect(html).toContain('Use &lt;b&gt;this&lt;/b&gt; &amp; that<br>line two');
    expect(html).toContain('Help24 Support');
    expect(html).not.toMatch(/<script/i);
    // One image only: the Help24 logo, with alt text for clients that block it.
    expect(html.match(/<img /g)).toHaveLength(1);
    expect(html).toContain('alt="Help24"');
  });

  it('a security reply says so in its header', () => {
    expect(replyHtml('Hi', 'Help24 Security')).toContain('>Security</span>');
    expect(replyHtml('Hi')).toContain('>Support</span>');
  });
});
