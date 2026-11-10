import { BadRequestException, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomUUID } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';
import { AdminContext } from '../admin/auth/admin-role';
import { MailNotSentError, OutboundEmail, SupportMailerService } from './support-mailer.service';
import { SupportService } from './support.service';
import { SupportInboundController } from './support-inbound.controller';
import { InboundEmail, signInbound } from './support-rules';

type Row = Record<string, any>;

/** The unique columns migration 138 declares, enforced like Postgres does (23505). */
const UNIQUE: Record<string, string[]> = {
  support_conversations: ['id', 'ref'],
  support_messages: ['id', 'email_message_id'],
};

/**
 * The PostgREST chains SupportService uses, over in-memory rows. Every row
 * gets a strictly increasing created_at, so "newest first" is never a tie.
 */
function fakeDb(tables: Record<string, Row[]>) {
  let tick = 0;
  const stamp = () => new Date(Date.now() - 3_600_000 + tick++ * 1000).toISOString();
  const defaults: Record<string, () => Row> = {
    support_conversations: () => ({ status: 'open', last_message_at: stamp(), created_at: stamp(), contact_name: null, user_id: null }),
    support_messages: () => ({
      created_at: stamp(), internal: false, attachment_count: 0, delivery: null, delivery_error: null,
      admin_id: null, full_body: null, email_message_id: null, sender_verified: null,
    }),
  };

  function from(table: string) {
    const rows = () => (tables[table] ??= []);
    let op: 'select' | 'insert' | 'update' = 'select';
    let payload: any = null;
    const filters: Array<(r: Row) => boolean> = [];
    let order: [string, boolean] | null = null;
    let limit = Infinity;
    let head = false;
    let single: 'single' | 'maybe' | null = null;

    const exec = () => {
      if (op === 'insert') {
        const inserted: Row[] = [];
        for (const p of Array.isArray(payload) ? payload : [payload]) {
          const row = { id: randomUUID(), ...(defaults[table]?.() ?? {}), ...p };
          for (const col of UNIQUE[table] ?? []) {
            if (row[col] != null && rows().some((r) => r[col] === row[col])) {
              return { data: null, error: { code: '23505', message: `duplicate ${col}` } };
            }
          }
          rows().push(row);
          inserted.push(row);
        }
        return { data: single ? inserted[0] : inserted, error: null };
      }
      let matched = rows().filter((r) => filters.every((f) => f(r)));
      if (op === 'update') {
        matched.forEach((r) => Object.assign(r, payload));
        return { data: null, error: null };
      }
      if (order) {
        const [c, asc] = order;
        matched = [...matched].sort((a, b) => (a[c] > b[c] ? 1 : a[c] < b[c] ? -1 : 0) * (asc ? 1 : -1));
      }
      matched = matched.slice(0, limit);
      if (head) return { data: null, count: matched.length, error: null };
      if (single === 'maybe') return { data: matched[0] ?? null, error: null };
      if (single === 'single') return matched[0] ? { data: matched[0], error: null } : { data: null, error: { message: 'no rows' } };
      return { data: matched, error: null };
    };

    const b: any = {
      select: (_cols?: string, opts?: { head?: boolean }) => {
        if (op === 'select' && opts?.head) head = true;
        return b;
      },
      insert: (p: any) => ((op = 'insert'), (payload = p), b),
      update: (p: any) => ((op = 'update'), (payload = p), b),
      eq: (c: string, v: unknown) => (filters.push((r) => r[c] === v), b),
      neq: (c: string, v: unknown) => (filters.push((r) => r[c] !== v), b),
      in: (c: string, vs: unknown[]) => (filters.push((r) => vs.includes(r[c])), b),
      gte: (c: string, v: string) => (filters.push((r) => r[c] >= v), b),
      not: (c: string, _op: string, _v: null) => (filters.push((r) => r[c] != null), b),
      ilike: (c: string, pattern: string) => {
        const literal = pattern.replace(/\\(.)/g, '$1').toLowerCase();
        filters.push((r) => String(r[c] ?? '').toLowerCase() === literal);
        return b;
      },
      order: (c: string, o: { ascending: boolean }) => ((order = [c, o.ascending]), b),
      limit: (n: number) => ((limit = n), b),
      maybeSingle: () => ((single = 'maybe'), b),
      single: () => ((single = 'single'), b),
      then: (res: any, rej: any) => Promise.resolve(exec()).then(res, rej),
    };
    return b;
  }
  return { client: { from } } as unknown as SupabaseService;
}

const ADMIN: AdminContext = { id: 'a0000000-0000-4000-8000-000000000001', email: 'agent@help24.co.ke', name: 'Wanjiru', role: 'support_agent' };

function setup(opts: { failSend?: boolean } = {}) {
  const tables: Record<string, Row[]> = {
    users: [{ id: 'FirebaseUid123', email: 'Mary.Wanjiku@Example.com', name: 'Mary Wanjiku', phone_number: '0712345678', created_at: '2026-09-01T00:00:00Z', last_seen: null }],
    admin_users: [{ id: ADMIN.id, name: 'Wanjiru', email: ADMIN.email }],
    support_conversations: [],
    support_messages: [],
  };
  const sent: OutboundEmail[] = [];
  let failing = opts.failSend ?? false;
  const mailer = {
    send: jest.fn(async (mail: OutboundEmail) => {
      if (failing) throw new MailNotSentError('Email sending is not set up on the server (RESEND_API_KEY).');
      sent.push(mail);
      return { providerId: 're_1' };
    }),
  } as unknown as SupportMailerService;
  const service = new SupportService(fakeDb(tables), mailer);
  return { service, tables, sent, setFailing: (v: boolean) => (failing = v) };
}

function email(over: Partial<InboundEmail> = {}): InboundEmail {
  return {
    from: { address: 'mary.wanjiku@example.com', name: 'Mary Wanjiku' },
    to: ['support@help24.co.ke'],
    subject: 'Payout not received',
    text: 'Hello, my payout has not arrived.',
    messageId: `<${randomUUID()}@mail.example.com>`,
    inReplyTo: null,
    references: [],
    authResults: ['mx.cloudflare.net; dkim=pass header.d=example.com; dmarc=pass'],
    attachments: 0,
    automated: false,
    ...over,
  };
}

describe('SupportService — mail in', () => {
  it('a new email opens a Support thread, linked to the member by email for display', async () => {
    const { service, tables } = setup();
    const r = await service.ingest(email());
    expect(r.result).toBe('stored');
    const [c] = tables.support_conversations;
    expect(c).toMatchObject({ label: 'support', status: 'open', subject: 'Payout not received', contact_email: 'mary.wanjiku@example.com', user_id: 'FirebaseUid123', started_by: 'member' });
    expect(c.ref).toMatch(/^H24-[A-HJ-NP-Z2-9]{6}$/);
    expect(tables.support_messages[0]).toMatchObject({ author: 'member', channel: 'email', body: 'Hello, my payout has not arrived.', sender_verified: true });
  });

  it('the same email delivered twice is stored once', async () => {
    const { service, tables } = setup();
    const e = email();
    await service.ingest(e);
    expect((await service.ingest(e)).result).toBe('duplicate');
    expect(tables.support_messages).toHaveLength(1);
  });

  it('a reply carrying the reference joins its thread and reopens it, even when closed', async () => {
    const { service, tables } = setup();
    await service.ingest(email());
    const c = tables.support_conversations[0];
    c.status = 'closed';
    await service.ingest(email({ subject: `Re: Payout not received [${c.ref}]`, text: 'Any news?\n\nOn Mon, Help24 Support wrote:\n> We are checking.' }));
    expect(tables.support_conversations).toHaveLength(1);
    expect(c.status).toBe('open');
    expect(tables.support_messages[1]).toMatchObject({ body: 'Any news?' });
    expect(tables.support_messages[1].full_body).toContain('We are checking.');
  });

  it('a reference alone is not enough: the same reference from another sender opens its own thread', async () => {
    const { service, tables } = setup();
    await service.ingest(email());
    const ref = tables.support_conversations[0].ref;
    await service.ingest(email({ from: { address: 'stranger@example.net' }, subject: `Re: x [${ref}]` }));
    expect(tables.support_conversations).toHaveLength(2);
    expect(tables.support_conversations[1].contact_email).toBe('stranger@example.net');
  });

  it('In-Reply-To pointing at our reply finds the thread', async () => {
    const { service, tables, sent } = setup();
    await service.ingest(email());
    const c = tables.support_conversations[0];
    await service.reply(c.id, ADMIN, 'We are checking.');
    const ours = sent[0].headers['Message-ID'];
    await service.ingest(email({ subject: 'Different words entirely', inReplyTo: ours }));
    expect(tables.support_conversations).toHaveLength(1);
    expect(tables.support_messages.filter((m) => m.author === 'member')).toHaveLength(2);
  });

  it('same sender and subject within the window joins the open thread; a new subject opens a new one', async () => {
    const { service, tables } = setup();
    await service.ingest(email());
    await service.ingest(email({ subject: 'Re: payout NOT received' }));
    expect(tables.support_conversations).toHaveLength(1);
    await service.ingest(email({ subject: 'How do I change my phone number?' }));
    expect(tables.support_conversations).toHaveLength(2);
  });

  it('info@ is the General inbox', async () => {
    const { service, tables } = setup();
    await service.ingest(email({ to: ['info@help24.co.ke'], subject: 'Partnership' }));
    expect(tables.support_conversations[0].label).toBe('general');
  });

  it('security@ is its own inbox, even when support@ is copied in', async () => {
    const { service, tables } = setup();
    await service.ingest(email({ to: ['security@help24.co.ke', 'support@help24.co.ke'], subject: 'Possible vulnerability' }));
    expect(tables.support_conversations[0].label).toBe('security');
  });

  it('auto-replies and our own domain are ignored, so replies never loop', async () => {
    const { service, tables } = setup();
    expect((await service.ingest(email({ automated: true }))).result).toBe('ignored');
    expect((await service.ingest(email({ from: { address: 'support@help24.co.ke' } }))).result).toBe('ignored');
    expect((await service.ingest(email({ to: ['someone@gmail.com'] }))).result).toBe('ignored');
    expect(tables.support_conversations).toHaveLength(0);
  });
});

describe('SupportService — the Inbox', () => {
  it('a reply is emailed from support@ as Help24 Support, threaded, and the thread then waits on the member', async () => {
    const { service, tables, sent } = setup();
    const e = email();
    await service.ingest(e);
    const c = tables.support_conversations[0];
    const r = await service.reply(c.id, ADMIN, 'Your payout went out today.');
    expect(r.delivery).toBe('sent');
    expect(sent[0]).toMatchObject({
      from: 'Help24 Support <support@help24.co.ke>',
      to: 'mary.wanjiku@example.com',
      replyTo: 'support@help24.co.ke',
      subject: `Re: Payout not received [${c.ref}]`,
      idempotencyKey: `support-${r.id}`,
    });
    expect(sent[0].headers['In-Reply-To']).toBe(e.messageId);
    expect(sent[0].headers.References).toContain(e.messageId);
    expect(sent[0].text).toMatch(/Your payout went out today\.\n\nHelp24 Support/);
    expect(sent[0].text).not.toContain('Wanjiru'); // the member never sees which admin wrote it
    expect(tables.support_messages.find((m) => m.id === r.id)).toMatchObject({ author: 'staff', admin_id: ADMIN.id, delivery: 'sent' });
    expect(c.status).toBe('waiting');
  });

  it('a reply that cannot be sent is kept and marked, the thread stays open, and it can be sent again', async () => {
    const { service, tables, sent, setFailing } = setup({ failSend: true });
    await service.ingest(email());
    const c = tables.support_conversations[0];
    const r = await service.reply(c.id, ADMIN, 'Checking now.');
    expect(r.delivery).toBe('failed');
    expect(r.delivery_error).toContain('RESEND_API_KEY');
    expect(c.status).toBe('open');
    setFailing(false);
    const again = await service.retry(c.id, r.id);
    expect(again.delivery).toBe('sent');
    expect(sent).toHaveLength(1);
    expect(sent[0].idempotencyKey).toBe(`support-${r.id}`);
    expect(c.status).toBe('waiting');
    await expect(service.retry(c.id, r.id)).rejects.toBeInstanceOf(BadRequestException);
  });

  it('an internal note is never sent and does not change the status', async () => {
    const { service, tables, sent } = setup();
    await service.ingest(email());
    const c = tables.support_conversations[0];
    await service.note(c.id, ADMIN, 'Check the B2C log first.');
    expect(sent).toHaveLength(0);
    expect(tables.support_messages[1]).toMatchObject({ internal: true, channel: 'note', author: 'staff' });
    expect(c.status).toBe('open');
  });

  it('empty or oversized text is refused before anything is stored', async () => {
    const { service, tables } = setup();
    await service.ingest(email());
    const c = tables.support_conversations[0];
    await expect(service.reply(c.id, ADMIN, '   ')).rejects.toBeInstanceOf(BadRequestException);
    await expect(service.note(c.id, ADMIN, 'x'.repeat(10001))).rejects.toBeInstanceOf(BadRequestException);
    expect(tables.support_messages).toHaveLength(1);
  });

  it('staff can write first; a help24.co.ke address is refused', async () => {
    const { service, tables, sent } = setup();
    const r = await service.start(ADMIN, { email: 'Mary.Wanjiku@example.com', subject: 'About your verification', body: 'Please resend your ID.' });
    expect(r.delivery).toBe('sent');
    expect(tables.support_conversations[0]).toMatchObject({ started_by: 'staff', contact_email: 'mary.wanjiku@example.com', user_id: 'FirebaseUid123', status: 'waiting' });
    expect(sent[0].headers['In-Reply-To']).toBeUndefined();
    await expect(service.start(ADMIN, { email: 'info@help24.co.ke', subject: 'x', body: 'y' })).rejects.toBeInstanceOf(BadRequestException);
  });

  it('the list counts each status and previews the last message a member could see, never a note', async () => {
    const { service, tables } = setup();
    await service.ingest(email());
    const c = tables.support_conversations[0];
    await service.reply(c.id, ADMIN, 'On it.');
    await service.note(c.id, ADMIN, 'Internal only.');
    const res = await service.list({});
    expect(res.counts).toEqual({ open: 0, waiting: 1, closed: 0 });
    expect(res.conversations[0].preview).toEqual({ author: 'staff', body: 'On it.' });
  });

  it('security@ mail is answered from security@ as Help24 Security', async () => {
    const { service, tables, sent } = setup();
    await service.ingest(email({ to: ['security@help24.co.ke'], subject: 'Reset email question' }));
    const c = tables.support_conversations[0];
    await service.reply(c.id, ADMIN, 'Thanks, we are looking into it.');
    expect(sent[0]).toMatchObject({ from: 'Help24 Security <security@help24.co.ke>', replyTo: 'security@help24.co.ke' });
    expect(sent[0].text).toMatch(/looking into it\.\n\nHelp24 Security\n/);
    expect(sent[0].html).toContain('Help24 Security');
    expect(sent[0].text).not.toContain('Help24 Support');
  });

  it('security@ mail never mixes into the support view: it is listed and counted only on its own', async () => {
    const { service } = setup();
    await service.ingest(email());
    await service.ingest(email({ to: ['info@help24.co.ke'], subject: 'Partnership' }));
    await service.ingest(email({ to: ['security@help24.co.ke'], subject: 'Strange sign-in' }));

    const every = await service.list({});
    expect(every.conversations.map((c) => c.label).sort()).toEqual(['general', 'support']);
    expect(every.counts.open).toBe(2);
    expect(every.open_by_label).toEqual({ support: 1, general: 1, security: 1 });

    const security = await service.list({ label: 'security' });
    expect(security.conversations.map((c) => c.subject)).toEqual(['Strange sign-in']);
    expect(security.counts.open).toBe(1);

    expect((await service.list({ label: 'bogus' })).conversations).toHaveLength(2); // unknown label = the support view
  });

  it('a conversation shows its messages with who wrote them, and the member behind the address', async () => {
    const { service, tables } = setup();
    await service.ingest(email());
    const c = tables.support_conversations[0];
    await service.reply(c.id, ADMIN, 'On it.');
    const res = await service.get(c.id);
    expect(res.member).toMatchObject({ id: 'FirebaseUid123', name: 'Mary Wanjiku' });
    expect(res.messages.map((m: Row) => m.author)).toEqual(['member', 'staff']);
    expect(res.messages[1].admin_name).toBe('Wanjiru');
  });
});

describe('SupportInboundController', () => {
  const config = (secret?: string) => ({ get: () => secret }) as unknown as ConfigService;
  const deliver = (secret: string, body: object, at = Math.floor(Date.now() / 1000)) => {
    const payload = Buffer.from(JSON.stringify(body)).toString('base64');
    return { timestamp: at, payload, signature: signInbound(secret, at, payload) };
  };
  const json = { from: { address: 'mary.wanjiku@example.com' }, to: ['support@help24.co.ke'], subject: 'Hi', text: 'Hello', messageId: '<m1@example.com>' };

  it('a correctly signed email is stored', async () => {
    const { service, tables } = setup();
    const controller = new SupportInboundController(service, config('k'));
    await expect(controller.inbound(deliver('k', json))).resolves.toMatchObject({ result: 'stored' });
    expect(tables.support_messages).toHaveLength(1);
  });

  it('a wrong secret or a stale signature is refused, and nothing is stored', async () => {
    const { service, tables } = setup();
    const controller = new SupportInboundController(service, config('k'));
    await expect(controller.inbound(deliver('other', json))).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(controller.inbound(deliver('k', json, Math.floor(Date.now() / 1000) - 600))).rejects.toBeInstanceOf(UnauthorizedException);
    expect(tables.support_messages).toHaveLength(0);
  });

  it('without a configured secret the endpoint is closed', async () => {
    const { service } = setup();
    const controller = new SupportInboundController(service, config(undefined));
    await expect(controller.inbound(deliver('k', json))).rejects.toThrow('not configured');
  });
});
