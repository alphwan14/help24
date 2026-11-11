import { BadRequestException, NotFoundException, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { randomUUID } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';
import { AdminContext } from '../admin/auth/admin-role';
import { NotificationPayload, NotificationsService } from '../notifications/notifications.service';
import { MailNotSentError, OutboundEmail, SupportMailerService } from './support-mailer.service';
import { SupportService } from './support.service';
import { SupportStorageService } from './support-storage.service';
import { SupportInboundController } from './support-inbound.controller';
import { InboundEmail, signInbound } from './support-rules';

type Row = Record<string, any>;

/** The unique columns migrations 138 and 142 declare, enforced like Postgres does (23505). */
const UNIQUE: Record<string, string[]> = {
  support_conversations: ['id', 'ref'],
  support_messages: ['id', 'email_message_id', 'client_id'],
};

/**
 * The PostgREST chains SupportService uses, over in-memory rows. Every row
 * gets a strictly increasing created_at, so "newest first" is never a tie.
 */
function fakeDb(tables: Record<string, Row[]>, bucket: unknown = fakeBucket(new Set())) {
  let tick = 0;
  const stamp = () => new Date(Date.now() - 3_600_000 + tick++ * 1000).toISOString();
  const defaults: Record<string, () => Row> = {
    support_conversations: () => ({
      status: 'open', last_message_at: stamp(), created_at: stamp(), contact_name: null, user_id: null,
      reply_via: 'email', member_read_at: null,
    }),
    support_messages: () => ({
      created_at: stamp(), internal: false, attachment_count: 0, delivery: null, delivery_error: null,
      admin_id: null, full_body: null, email_message_id: null, sender_verified: null, attachments: [],
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
  return { client: { from, storage: { from: () => bucket } } } as unknown as SupabaseService;
}

/** The private support-attachments bucket: signs links, lists what was uploaded. */
function fakeBucket(uploaded: Set<string>) {
  return {
    createSignedUploadUrl: async (path: string) => ({ data: { signedUrl: `https://storage.test/upload/${path}`, token: 'tok' }, error: null }),
    list: async (dir: string, opts?: { search?: string }) => ({
      data: [...uploaded].filter((p) => p.startsWith(`${dir}/`)).map((p) => ({ name: p.slice(dir.length + 1) }))
        .filter((o) => !opts?.search || o.name === opts.search),
      error: null,
    }),
    createSignedUrl: async (path: string, ttl: number) => ({ data: { signedUrl: `https://storage.test/signed/${path}?ttl=${ttl}` }, error: null }),
    download: async (path: string) =>
      uploaded.has(path) ? { data: new Blob([`bytes of ${path}`]), error: null } : { data: null, error: { message: 'Object not found' } },
  };
}

const ADMIN: AdminContext = { id: 'a0000000-0000-4000-8000-000000000001', email: 'agent@help24.co.ke', name: 'Wanjiru', role: 'support_agent' };

function setup(opts: { failSend?: boolean; failPush?: boolean } = {}) {
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
  const pushed: NotificationPayload[] = [];
  const notifications = {
    send: jest.fn(async (p: NotificationPayload) => {
      if (opts.failPush) throw new Error('FCM is down');
      pushed.push(p);
    }),
  } as unknown as NotificationsService;
  const uploaded = new Set<string>();
  const supabase = fakeDb(tables, fakeBucket(uploaded));
  const storageConfig = {
    get: (k: string) => ({ SUPABASE_SERVICE_ROLE_KEY: 'service-role-key-for-tests', PUBLIC_API_URL: 'https://api.test/' } as Row)[k],
  } as unknown as ConfigService;
  const service = new SupportService(supabase, mailer, notifications, new SupportStorageService(supabase, storageConfig));
  return { service, tables, sent, pushed, uploaded, setFailing: (v: boolean) => (failing = v) };
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

  it('staff can write first from security@: sent as Help24 Security, and the thread lives under Security', async () => {
    const { service, tables, sent } = setup();
    await service.start(ADMIN, { email: 'mary.wanjiku@example.com', subject: 'A sign-in we did not expect', body: 'Was this you?', from: 'security' });
    expect(tables.support_conversations[0].label).toBe('security');
    expect(sent[0]).toMatchObject({ from: 'Help24 Security <security@help24.co.ke>', replyTo: 'security@help24.co.ke' });
    expect(sent[0].text).toMatch(/\n\nHelp24 Security\n/);
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

describe('SupportService — Message Help24 (the app)', () => {
  const MARY = 'FirebaseUid123';
  const id = () => randomUUID();

  it('the first message opens the member\'s thread, answered in the app, titled by what they wrote', async () => {
    const { service, tables } = setup();
    expect(await service.appThread(MARY)).toEqual({ conversation: null, messages: [], unread: 0 });
    const r = await service.appSend(MARY, 'My payout has not arrived\nIt was due yesterday.', id());
    const [c] = tables.support_conversations;
    expect(c).toMatchObject({
      label: 'support', reply_via: 'app', status: 'open', started_by: 'member', user_id: MARY,
      subject: 'My payout has not arrived', contact_email: 'mary.wanjiku@example.com', contact_name: 'Mary Wanjiku',
    });
    expect(tables.support_messages[0]).toMatchObject({ author: 'member', channel: 'app', sender_verified: true });
    expect(r.conversation).toEqual({ id: c.id, ref: c.ref, status: 'open' });
  });

  it('every later message joins the same thread, and a closed one reopens', async () => {
    const { service, tables } = setup();
    await service.appSend(MARY, 'First', id());
    tables.support_conversations[0].status = 'closed';
    await service.appSend(MARY, 'One more thing', id());
    expect(tables.support_conversations).toHaveLength(1);
    expect(tables.support_conversations[0].status).toBe('open');
    expect((await service.appThread(MARY)).messages.map((m) => m.body)).toEqual(['First', 'One more thing']);
  });

  it('a retried send is stored once; another member cannot reuse its id', async () => {
    const { service, tables } = setup();
    tables.users.push({ id: 'OtherUid', email: null, name: null });
    const clientId = id();
    const first = await service.appSend(MARY, 'Hello', clientId);
    const again = await service.appSend(MARY, 'Hello', clientId);
    expect(again.message.id).toBe(first.message.id);
    expect(tables.support_messages).toHaveLength(1);
    await expect(service.appSend('OtherUid', 'Hi', clientId)).rejects.toBeInstanceOf(BadRequestException);
  });

  it('a member who signed up by phone (no email) can still write', async () => {
    const { service, tables } = setup();
    tables.users.push({ id: 'PhoneUid', email: null, name: 'Otieno' });
    await service.appSend('PhoneUid', 'Hi', id());
    expect(tables.support_conversations[0]).toMatchObject({ contact_email: null, contact_name: 'Otieno', user_id: 'PhoneUid' });
  });

  it('without a profile there is nothing to attach the thread to', async () => {
    const { service } = setup();
    await expect(service.appSend('NoSuchUid', 'Hi', id())).rejects.toBeInstanceOf(BadRequestException);
  });

  it('a staff answer goes into the app with a notification, never by email, and the thread waits on the member', async () => {
    const { service, tables, sent, pushed } = setup();
    await service.appSend(MARY, 'Payout question', id());
    const c = tables.support_conversations[0];
    const r = await service.reply(c.id, ADMIN, 'It went out this morning.\nCheck your M-Pesa messages.');
    expect(r).toMatchObject({ delivery: 'sent', delivery_error: null });
    expect(sent).toHaveLength(0);
    expect(tables.support_messages.at(-1)).toMatchObject({ author: 'staff', channel: 'app', admin_id: ADMIN.id, delivery: 'sent' });
    expect(pushed).toEqual([{
      userId: MARY, type: 'support_reply', title: 'Help24 Support',
      body: 'It went out this morning. Check your M-Pesa messages.', data: { conversation_id: c.id, screen: 'support' },
    }]);
    expect(c.status).toBe('waiting');
  });

  it('a failed push still leaves the answer delivered in the app', async () => {
    const { service, tables } = setup({ failPush: true });
    await service.appSend(MARY, 'Hello', id());
    const r = await service.reply(tables.support_conversations[0].id, ADMIN, 'Hi Mary.');
    expect(r.delivery).toBe('sent');
    expect((await service.appThread(MARY)).messages.map((m) => m.author)).toEqual(['member', 'staff']);
  });

  it('the app sees answers as Help24 only: no notes, no admin names; unread counts until opened', async () => {
    const { service, tables } = setup();
    await service.appSend(MARY, 'Hello', id());
    const c = tables.support_conversations[0];
    await service.note(c.id, ADMIN, 'Internal: check the B2C log.');
    await service.reply(c.id, ADMIN, 'Looking now.');
    const thread = await service.appThread(MARY);
    expect(thread.messages.map((m) => m.body)).toEqual(['Hello', 'Looking now.']);
    expect(Object.keys(thread.messages[1]).sort()).toEqual(['attachments', 'author', 'body', 'created_at', 'id']);
    expect(JSON.stringify(thread)).not.toContain('Wanjiru');
    expect(thread.unread).toBe(1);
    await service.appMarkRead(MARY);
    expect((await service.appThread(MARY)).unread).toBe(0);
  });

  it('photos: upload links are under the member\'s own prefix, and a photo-only message is stored and shown as links', async () => {
    const { service, tables, uploaded } = setup();
    const { files } = await service.appUploadUrls(MARY, [{ content_type: 'image/jpeg' }, { content_type: 'image/png' }]);
    expect(files.map((f) => f.path)).toEqual([
      expect.stringMatching(new RegExp(`^members/${MARY}/[0-9a-f-]{36}\\.jpg$`)),
      expect.stringMatching(new RegExp(`^members/${MARY}/[0-9a-f-]{36}\\.png$`)),
    ]);
    files.forEach((f) => uploaded.add(f.path));

    const r = await service.appSend(MARY, '   ', id(), files.map((f) => f.path));
    const [c] = tables.support_conversations;
    expect(c.subject).toBe('Photo');
    expect(tables.support_messages[0]).toMatchObject({
      body: '', attachment_count: 2,
      attachments: [{ path: files[0].path, mime: 'image/jpeg' }, { path: files[1].path, mime: 'image/png' }],
    });
    expect(r.message.attachments.map((a) => a.mime)).toEqual(['image/jpeg', 'image/png']);
    const thread = await service.appThread(MARY);
    const msgId = tables.support_messages[0].id;
    // Help24's own address: no storage provider, no member account id.
    expect(thread.messages[0].attachments[0].url).toMatch(new RegExp(`^https://api\\.test/support/photos/${msgId}/0\\?e=\\d+&s=[A-Za-z0-9_-]{43}$`));
    expect(JSON.stringify(thread)).not.toMatch(/storage\.test|members\//);
    expect((await service.get(c.id)).messages[0].attachments).toHaveLength(2); // staff see them in the Inbox
    expect((await service.list({})).conversations[0].preview).toEqual({ author: 'member', body: '2 photos' });
  });

  it('photo links: a genuine link serves the photo; tampered, expired, out-of-range or note links are not found', async () => {
    const { service, tables, uploaded } = setup();
    const { files } = await service.appUploadUrls(MARY, [{ content_type: 'image/png' }]);
    uploaded.add(files[0].path);
    await service.appSend(MARY, 'Screenshot', id(), [files[0].path]);
    const [, msgId, index, e, s] = /\/photos\/([^/]+)\/(\d+)\?e=(\d+)&s=(.+)$/.exec((await service.appThread(MARY)).messages[0].attachments[0].url)!;

    const photo = await service.photo(msgId, Number(index), Number(e), s);
    expect(photo).toMatchObject({ mime: 'image/png' });
    expect(photo.bytes.toString()).toBe(`bytes of ${files[0].path}`);

    const notFound = (p: Promise<unknown>) => expect(p).rejects.toBeInstanceOf(NotFoundException);
    await notFound(service.photo(msgId, Number(index), Number(e), `${s.slice(0, -1)}${s.endsWith('A') ? 'B' : 'A'}`));
    await notFound(service.photo(msgId, 1, Number(e), s)); // the signature names photo 0
    await notFound(service.photo(msgId, Number(index), Number(e) + 3600, s)); // a stretched expiry breaks the signature
    const past = Math.floor(Date.now() / 1000) - 10;
    await notFound(service.photo(msgId, Number(index), past, s));

    // A note is never served, even with a correctly signed link to it.
    tables.support_messages[0].internal = true;
    await notFound(service.photo(msgId, Number(index), Number(e), s));
  });

  it('photos: someone else\'s path, a path never uploaded, or a file that is not a photo is refused', async () => {
    const { service, tables, uploaded } = setup();
    tables.users.push({ id: 'OtherUid', email: null, name: null });
    const { files: theirs } = await service.appUploadUrls('OtherUid', [{ content_type: 'image/jpeg' }]);
    uploaded.add(theirs[0].path);
    await expect(service.appSend(MARY, 'Look', id(), [theirs[0].path])).rejects.toBeInstanceOf(BadRequestException);

    const { files: mine } = await service.appUploadUrls(MARY, [{ content_type: 'image/webp' }]);
    await expect(service.appSend(MARY, 'Look', id(), [mine[0].path])).rejects.toThrow('did not finish uploading');
    await expect(service.appSend(MARY, 'Look', id(), [`members/${MARY}/../../secrets.jpg`])).rejects.toBeInstanceOf(BadRequestException);
    await expect(service.appUploadUrls(MARY, [{ content_type: 'application/pdf' }])).rejects.toBeInstanceOf(BadRequestException);
    await expect(service.appSend(MARY, '  ', id())).rejects.toThrow('Write a message first.'); // no words and no photo
    expect(tables.support_messages).toHaveLength(0);
  });

  it('an email from the same member never joins their in-app thread', async () => {
    const { service, tables } = setup();
    await service.appSend(MARY, 'Payout not received', id());
    await service.ingest(email({ subject: 'Payout not received' }));
    expect(tables.support_conversations).toHaveLength(2);
    expect(tables.support_conversations.map((c) => c.reply_via).sort()).toEqual(['app', 'email']);
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
