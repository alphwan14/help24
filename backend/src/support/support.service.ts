import { BadRequestException, Injectable, Logger, NotFoundException, ServiceUnavailableException } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';
import { AdminContext } from '../admin/auth/admin-role';
import { NotificationsService } from '../notifications/notifications.service';
import { MailNotSentError, SupportMailerService } from './support-mailer.service';
import { ShownAttachment, SupportStorageService } from './support-storage.service';
import {
  INBOX_LABELS,
  InboundEmail,
  InboxLabel,
  THREAD_WINDOW_DAYS,
  identityFor,
  inboundBody,
  labelFor,
  makeRef,
  normalizeSubject,
  refInSubject,
  replyHtml,
  replySubject,
  replyText,
  senderVerified,
  threadSubject,
} from './support-rules';

export type ConversationStatus = 'open' | 'waiting' | 'closed';
const STATUSES: ConversationStatus[] = ['open', 'waiting', 'closed'];

type Row = Record<string, unknown>;

export interface Conversation {
  id: string;
  ref: string;
  label: InboxLabel;
  status: ConversationStatus;
  subject: string;
  /** Empty only for an app thread whose member has no email (migration 142). */
  contact_email: string | null;
  contact_name: string | null;
  user_id: string | null;
  started_by: 'member' | 'staff';
  /** Where Help24's answers go: by email, or into the app (migration 142). */
  reply_via: 'email' | 'app';
  /** When the member last opened the thread in the app. */
  member_read_at: string | null;
  last_message_at: string;
  created_at: string;
}

const CONVERSATION_COLUMNS =
  'id, ref, label, status, subject, contact_email, contact_name, user_id, started_by, reply_via, member_read_at, last_message_at, created_at';

/** What the app shows of one message: never which admin wrote it, never a note. */
export interface AppMessage {
  id: string;
  author: 'member' | 'staff';
  body: string;
  /** Photos (migration 143), as short-lived links. */
  attachments: ShownAttachment[];
  created_at: string;
}
const MESSAGE_COLUMNS =
  'id, conversation_id, author, admin_id, internal, channel, body, full_body, email_message_id, sender_verified, attachment_count, attachments, delivery, delivery_error, created_at';

const MAX_REPLY = 10000;

/** "a_b%c" → "a\_b\%c": an email address as a literal ILIKE pattern. */
const literal = (s: string) => s.replace(/[\\%_]/g, (c) => `\\${c}`);

/**
 * The support Inbox (migration 138). Email arrives through workers/help24-mail
 * and SupportInboundController; staff work it from the dashboard through
 * SupportAdminController. Replies leave by email from support@, signed
 * "Help24 Support", and are kept whether or not sending worked.
 */
@Injectable()
export class SupportService {
  private readonly logger = new Logger(SupportService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly mailer: SupportMailerService,
    private readonly notifications: NotificationsService,
    private readonly storage: SupportStorageService,
  ) {}

  private get db() {
    return this.supabase.client;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Mail in
  // ═══════════════════════════════════════════════════════════════════════════

  /**
   * Store one inbound email in its thread. Idempotent on the Message-ID: the
   * Worker retries, and a second delivery of the same email changes nothing.
   */
  async ingest(email: InboundEmail): Promise<{ result: 'stored' | 'duplicate' | 'ignored'; conversationId?: string }> {
    // Auto-replies, bounces and bulk mail would otherwise answer our replies
    // and each other forever; mail from our own domain is a loop.
    if (email.automated || email.from.address.endsWith('@help24.co.ke')) return { result: 'ignored' };
    const label = labelFor(email.to);
    if (!label) return { result: 'ignored' };

    if (email.messageId) {
      const { data: seen, error } = await this.db
        .from('support_messages').select('conversation_id').eq('email_message_id', email.messageId).maybeSingle();
      if (error) throw new ServiceUnavailableException('Could not store the email right now.');
      if (seen) return { result: 'duplicate', conversationId: seen.conversation_id as string };
    }

    const conversation = (await this.findThread(email, label)) ?? (await this.createConversation({
      label,
      subject: threadSubject(email.subject),
      contactEmail: email.from.address,
      contactName: email.from.name ?? null,
      startedBy: 'member',
    }));

    const { body, full } = inboundBody(email.text);
    const { error } = await this.db.from('support_messages').insert({
      conversation_id: conversation.id,
      author: 'member',
      channel: 'email',
      body,
      full_body: full,
      email_message_id: email.messageId,
      sender_verified: senderVerified(email.authResults, email.from.address),
      attachment_count: email.attachments,
    });
    if (error) {
      if (error.code === '23505') return { result: 'duplicate', conversationId: conversation.id };
      this.logger.error(`[SUPPORT] could not store an inbound email: ${error.message}`);
      throw new ServiceUnavailableException('Could not store the email right now.');
    }

    // The member wrote last: the thread waits on Help24 again, even if it was closed.
    await this.touch(conversation.id, { status: 'open' });
    return { result: 'stored', conversationId: conversation.id };
  }

  /**
   * The thread an email belongs to, by: the reference in its subject; the
   * In-Reply-To/References headers against messages we hold; or the same
   * sender's open thread on the same subject within THREAD_WINDOW_DAYS. The
   * first two also need the same sender: a reference or a Message-ID alone is
   * not proof enough to write into someone's conversation.
   */
  private async findThread(email: InboundEmail, label: InboxLabel): Promise<Conversation | null> {
    const sender = email.from.address;

    // Email never joins an in-app conversation: those are answered in the app,
    // where the member is signed in, and an email's sender could be forged.
    const ref = refInSubject(email.subject);
    if (ref) {
      const { data } = await this.db.from('support_conversations').select(CONVERSATION_COLUMNS)
        .eq('ref', ref).eq('contact_email', sender).neq('reply_via', 'app').maybeSingle();
      if (data) return data as unknown as Conversation;
    }

    const ids = [...new Set([email.inReplyTo, ...email.references].filter((x): x is string => !!x))].slice(0, 20);
    if (ids.length) {
      const { data: msgs } = await this.db.from('support_messages').select('conversation_id').in('email_message_id', ids).limit(20);
      const convIds = [...new Set((msgs ?? []).map((m: Row) => m.conversation_id as string))];
      if (convIds.length) {
        const { data } = await this.db.from('support_conversations').select(CONVERSATION_COLUMNS)
          .in('id', convIds).eq('contact_email', sender).neq('reply_via', 'app')
          .order('last_message_at', { ascending: false }).limit(1);
        if (data?.[0]) return data[0] as unknown as Conversation;
      }
    }

    const since = new Date(Date.now() - THREAD_WINDOW_DAYS * 86_400_000).toISOString();
    const { data: recent } = await this.db.from('support_conversations').select(CONVERSATION_COLUMNS)
      .eq('contact_email', sender).eq('label', label).neq('reply_via', 'app').in('status', ['open', 'waiting'])
      .gte('last_message_at', since).order('last_message_at', { ascending: false }).limit(10);
    const subject = normalizeSubject(email.subject);
    const same = (recent ?? []).find((c: Row) => subject !== '' && normalizeSubject(c.subject as string) === subject);
    return (same as unknown as Conversation) ?? null;
  }

  private async createConversation(input: {
    label: InboxLabel;
    subject: string;
    contactEmail: string;
    contactName: string | null;
    startedBy: 'member' | 'staff';
  }): Promise<Conversation> {
    const userId = await this.memberIdFor(input.contactEmail);
    for (let attempt = 0; attempt < 4; attempt++) {
      const { data, error } = await this.db.from('support_conversations').insert({
        ref: makeRef(),
        label: input.label,
        status: 'open',
        subject: input.subject,
        contact_email: input.contactEmail,
        contact_name: input.contactName,
        user_id: userId,
        started_by: input.startedBy,
      }).select(CONVERSATION_COLUMNS).single();
      if (!error) return data as unknown as Conversation;
      // A reference already taken: draw another.
      if (error.code !== '23505') {
        this.logger.error(`[SUPPORT] could not open a conversation: ${error.message}`);
        throw new ServiceUnavailableException('Could not open the conversation right now.');
      }
    }
    throw new ServiceUnavailableException('Could not open the conversation right now.');
  }

  /** The member whose account uses this email, if any. For display only. */
  private async memberIdFor(email: string): Promise<string | null> {
    const { data } = await this.db.from('users').select('id').ilike('email', literal(email)).limit(1);
    return (data?.[0]?.id as string | undefined) ?? null;
  }

  private async touch(id: string, patch: { status?: ConversationStatus }): Promise<void> {
    const { error } = await this.db.from('support_conversations')
      .update({ ...patch, last_message_at: new Date().toISOString() }).eq('id', id);
    if (error) this.logger.warn(`[SUPPORT] could not update conversation ${id}: ${error.message}`);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // The Inbox (dashboard)
  // ═══════════════════════════════════════════════════════════════════════════

  /**
   * Conversations, newest activity first, with counts per status. Without a
   * label this is support@ and info@ together; security@ mail is only ever
   * listed on its own, so it never mixes with member support.
   */
  async list(filter: { status?: string; label?: string }) {
    const status = STATUSES.includes(filter.status as ConversationStatus) ? (filter.status as ConversationStatus) : null;
    const label = INBOX_LABELS.includes(filter.label as InboxLabel) ? (filter.label as InboxLabel) : null;
    // PostgREST builders differ per call site; this only narrows by label.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const scoped = <Q extends { eq: any; neq: any }>(query: Q): Q =>
      label ? query.eq('label', label) : query.neq('label', 'security');

    let q = scoped(this.db.from('support_conversations').select(CONVERSATION_COLUMNS)
      .order('last_message_at', { ascending: false }).limit(200));
    if (status) q = q.eq('status', status);
    const { data, error } = await q;
    if (error) throw new ServiceUnavailableException('Could not read the Inbox right now.');
    const conversations = (data ?? []) as unknown as Conversation[];

    const ids = conversations.map((c) => c.id);
    const previews = new Map<string, { author: string; body: string }>();
    if (ids.length) {
      const { data: msgs } = await this.db.from('support_messages').select('conversation_id, author, body, attachments, created_at')
        .in('conversation_id', ids).eq('internal', false).order('created_at', { ascending: false }).limit(1000);
      for (const m of (msgs ?? []) as Row[]) {
        const id = m.conversation_id as string;
        if (!previews.has(id)) previews.set(id, { author: m.author as string, body: previewOf(m) });
      }
    }

    const counts: Record<ConversationStatus, number> = { open: 0, waiting: 0, closed: 0 };
    const openByLabel: Record<InboxLabel, number> = { support: 0, general: 0, security: 0 };
    await Promise.all([
      ...STATUSES.map(async (s) => {
        const { count } = await scoped(this.db.from('support_conversations').select('id', { count: 'exact', head: true }).eq('status', s));
        counts[s] = count ?? 0;
      }),
      ...INBOX_LABELS.map(async (l) => {
        const { count } = await this.db.from('support_conversations').select('id', { count: 'exact', head: true })
          .eq('status', 'open').eq('label', l);
        openByLabel[l] = count ?? 0;
      }),
    ]);

    return {
      counts,
      open_by_label: openByLabel,
      conversations: conversations.map((c) => ({ ...c, preview: previews.get(c.id) ?? null })),
    };
  }

  /** One conversation, all its messages (notes included), and who the member is. */
  async get(id: string) {
    const conversation = await this.conversation(id);
    const { data: msgs, error } = await this.db.from('support_messages').select(MESSAGE_COLUMNS)
      .eq('conversation_id', id).order('created_at', { ascending: true }).limit(500);
    if (error) throw new ServiceUnavailableException('Could not read the conversation right now.');
    const messages = (msgs ?? []) as Row[];

    const adminIds = [...new Set(messages.map((m) => m.admin_id as string | null).filter((x): x is string => !!x))];
    const admins = new Map<string, string>();
    if (adminIds.length) {
      const { data } = await this.db.from('admin_users').select('id, name, email').in('id', adminIds);
      for (const a of (data ?? []) as Row[]) admins.set(a.id as string, ((a.name as string) || (a.email as string)) ?? 'Admin');
    }

    let member: Row | null = null;
    if (conversation.user_id) {
      const { data } = await this.db.from('users').select('id, name, email, phone_number, created_at, last_seen')
        .eq('id', conversation.user_id).maybeSingle();
      member = data ?? null;
    }

    return {
      conversation,
      member,
      messages: await Promise.all(messages.map(async (m) => ({
        ...m,
        // Photos as short-lived signed links: the bucket is private, so a link
        // copied out of the Inbox stops working within the hour.
        attachments: await this.storage.show(m.attachments),
        admin_name: m.admin_id ? admins.get(m.admin_id as string) ?? null : null,
      }))),
    };
  }

  private async conversation(id: string): Promise<Conversation> {
    const { data, error } = await this.db.from('support_conversations').select(CONVERSATION_COLUMNS).eq('id', id).maybeSingle();
    if (error) throw new ServiceUnavailableException('Could not read the conversation right now.');
    if (!data) throw new NotFoundException('Conversation not found.');
    return data as unknown as Conversation;
  }

  /**
   * Reply to the member: by email, or into the app for an in-app thread. The
   * message is kept even if an email fails to send.
   */
  async reply(id: string, admin: AdminContext, text: string) {
    const body = cleanBody(text);
    const conversation = await this.conversation(id);
    if (conversation.reply_via === 'app') return this.replyInApp(conversation, admin, body);
    const messageId = randomUUID();
    const emailMessageId = `<${messageId}@help24.co.ke>`;
    const { error } = await this.db.from('support_messages').insert({
      id: messageId,
      conversation_id: id,
      author: 'staff',
      admin_id: admin.id,
      channel: 'email',
      body,
      email_message_id: emailMessageId,
      delivery: 'sending',
    });
    if (error) throw new ServiceUnavailableException('Could not save the reply right now.');
    return this.deliver(conversation, messageId, body, emailMessageId);
  }

  /** Send a reply that failed again (same message, same idempotency key). */
  async retry(id: string, messageId: string) {
    const conversation = await this.conversation(id);
    const { data: msg } = await this.db.from('support_messages').select(MESSAGE_COLUMNS)
      .eq('id', messageId).eq('conversation_id', id).maybeSingle();
    if (!msg) throw new NotFoundException('Message not found.');
    if (msg.author !== 'staff' || msg.channel !== 'email' || msg.delivery !== 'failed') {
      throw new BadRequestException('Only a reply that was not sent can be sent again.');
    }
    await this.db.from('support_messages').update({ delivery: 'sending', delivery_error: null }).eq('id', messageId);
    return this.deliver(conversation, messageId, msg.body as string, msg.email_message_id as string);
  }

  private async deliver(conversation: Conversation, messageId: string, body: string, emailMessageId: string) {
    // Thread it in the member's mail client: answer their latest email, and
    // carry the thread's recent ids.
    const { data: earlier } = await this.db.from('support_messages').select('author, email_message_id')
      .eq('conversation_id', conversation.id).not('email_message_id', 'is', null).neq('id', messageId)
      .order('created_at', { ascending: false }).limit(10);
    const ids = ((earlier ?? []) as Row[]).map((m) => m.email_message_id as string);
    const lastFromMember = ((earlier ?? []) as Row[]).find((m) => m.author === 'member')?.email_message_id as string | undefined;
    const headers: Record<string, string> = { 'Message-ID': emailMessageId };
    if (lastFromMember) headers['In-Reply-To'] = lastFromMember;
    if (ids.length) headers.References = [...ids].reverse().join(' ');

    const identity = identityFor(conversation.label);
    let delivery: 'sent' | 'failed' = 'sent';
    let deliveryError: string | null = null;
    try {
      if (!conversation.contact_email) throw new MailNotSentError('This conversation has no email address to answer.');
      await this.mailer.send({
        from: identity.from,
        to: conversation.contact_email,
        replyTo: identity.address,
        subject: replySubject(conversation.subject, conversation.ref),
        text: replyText(body, identity.signature),
        html: replyHtml(body, identity.signature),
        headers,
        idempotencyKey: `support-${messageId}`,
      });
    } catch (e) {
      delivery = 'failed';
      deliveryError = e instanceof MailNotSentError ? e.message : 'The email could not be sent.';
      this.logger.warn(`[SUPPORT] reply ${messageId} not sent: ${deliveryError}`);
    }

    await this.db.from('support_messages').update({ delivery, delivery_error: deliveryError }).eq('id', messageId);
    // Sent: the thread now waits on the member. Not sent: still on Help24.
    await this.touch(conversation.id, { status: delivery === 'sent' ? 'waiting' : 'open' });
    return { id: messageId, delivery, delivery_error: deliveryError };
  }

  /**
   * An answer to an in-app thread: stored, which is delivery (the app reads it
   * from here), then a notification and push so the member knows. A push that
   * fails costs nothing but speed: the answer is already in the app.
   */
  private async replyInApp(conversation: Conversation, admin: AdminContext, body: string) {
    const { data, error } = await this.db.from('support_messages').insert({
      conversation_id: conversation.id,
      author: 'staff',
      admin_id: admin.id,
      channel: 'app',
      body,
      delivery: 'sent',
    }).select('id').single();
    if (error || !data) throw new ServiceUnavailableException('Could not save the reply right now.');
    await this.touch(conversation.id, { status: 'waiting' });

    if (conversation.user_id) {
      try {
        await this.notifications.send({
          userId: conversation.user_id,
          type: 'support_reply',
          title: identityFor(conversation.label).signature,
          body: body.replace(/\s+/g, ' ').slice(0, 140),
          data: { conversation_id: conversation.id, screen: 'support' },
        });
      } catch (e) {
        this.logger.warn(`[SUPPORT] reply ${data.id} stored; the notification failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    }
    return { id: data.id as string, delivery: 'sent' as const, delivery_error: null };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Message Help24 (the app) — always the signed-in member's own thread
  // ═══════════════════════════════════════════════════════════════════════════

  /** The member's in-app thread: every message they can see, and how many answers are unread. */
  async appThread(userId: string): Promise<{
    conversation: { id: string; ref: string; status: ConversationStatus } | null;
    messages: AppMessage[];
    unread: number;
  }> {
    const conversation = await this.appConversation(userId);
    if (!conversation) return { conversation: null, messages: [], unread: 0 };
    const { data, error } = await this.db.from('support_messages').select('id, author, body, attachments, created_at')
      .eq('conversation_id', conversation.id).eq('internal', false)
      .order('created_at', { ascending: true }).limit(500);
    if (error) throw new ServiceUnavailableException('Could not load your messages right now.');
    const messages = await Promise.all(((data ?? []) as Row[]).map((m) => this.toAppMessage(m)));
    const readAt = conversation.member_read_at ? Date.parse(conversation.member_read_at) : 0;
    const unread = messages.filter((m) => m.author === 'staff' && Date.parse(m.created_at) > readAt).length;
    return { conversation: { id: conversation.id, ref: conversation.ref, status: conversation.status }, messages, unread };
  }

  /**
   * A message from the member, in the app. Opens their thread the first time;
   * after that it always joins the same one, reopening it if it was closed.
   * Idempotent on the app's client id: a retried send is stored once.
   */
  async appSend(
    userId: string,
    text: string,
    clientId: string,
    photoPaths: string[] = [],
  ): Promise<{ message: AppMessage; conversation: { id: string; ref: string; status: ConversationStatus } }> {
    // A message may be photos only; then it needs no words.
    const body = photoPaths.length ? cleanOptionalBody(text) : cleanBody(text);
    const existing = await this.appMessageByClientId(userId, clientId);
    if (existing) return existing;
    const attachments = await this.storage.verify(userId, photoPaths);

    const conversation = (await this.appConversation(userId)) ?? (await this.openAppConversation(userId, body || 'Photo'));
    const { data, error } = await this.db.from('support_messages').insert({
      conversation_id: conversation.id,
      author: 'member',
      channel: 'app',
      body,
      attachments,
      attachment_count: attachments.length,
      // Signed in to the app: the backend verified who sent it.
      sender_verified: true,
      client_id: clientId,
    }).select('id, author, body, attachments, created_at').single();
    if (error) {
      if (error.code === '23505') {
        const again = await this.appMessageByClientId(userId, clientId);
        if (again) return again;
      }
      this.logger.error(`[SUPPORT] could not store an app message: ${error.message}`);
      throw new ServiceUnavailableException('Could not send your message right now.');
    }
    await this.touch(conversation.id, { status: 'open' });
    return {
      message: await this.toAppMessage(data as Row),
      conversation: { id: conversation.id, ref: conversation.ref, status: 'open' },
    };
  }

  /** Signed upload links for the member's photos, under their own storage prefix. */
  appUploadUrls(userId: string, files: Array<{ content_type: string }>) {
    return this.storage.issueUploadUrls(userId, files);
  }

  /** One message as the app sees it: never notes, never which admin wrote it. */
  private async toAppMessage(m: Row): Promise<AppMessage> {
    return {
      id: m.id as string,
      author: m.author as 'member' | 'staff',
      body: m.body as string,
      attachments: await this.storage.show(m.attachments),
      created_at: m.created_at as string,
    };
  }

  /** The member opened their thread: answers so far count as read. */
  async appMarkRead(userId: string): Promise<{ ok: true }> {
    const { error } = await this.db.from('support_conversations')
      .update({ member_read_at: new Date().toISOString() }).eq('user_id', userId).eq('reply_via', 'app');
    if (error) throw new ServiceUnavailableException('Could not update your messages right now.');
    return { ok: true };
  }

  private async appConversation(userId: string): Promise<Conversation | null> {
    const { data, error } = await this.db.from('support_conversations').select(CONVERSATION_COLUMNS)
      .eq('user_id', userId).eq('reply_via', 'app').maybeSingle();
    if (error) throw new ServiceUnavailableException('Could not load your messages right now.');
    return (data as unknown as Conversation) ?? null;
  }

  /** A retried send: the message already stored under this client id, in this member's thread only. */
  private async appMessageByClientId(userId: string, clientId: string) {
    const { data: msg } = await this.db.from('support_messages').select('id, author, body, attachments, created_at, conversation_id')
      .eq('client_id', clientId).maybeSingle();
    if (!msg) return null;
    const conversation = await this.appConversation(userId);
    if (!conversation || conversation.id !== msg.conversation_id) {
      throw new BadRequestException('That message id is already taken.');
    }
    return {
      message: await this.toAppMessage(msg as Row),
      conversation: { id: conversation.id, ref: conversation.ref, status: conversation.status },
    };
  }

  /**
   * The member's first message from the app opens their thread: a Support
   * conversation answered in the app, titled by the first line they wrote.
   */
  private async openAppConversation(userId: string, firstMessage: string): Promise<Conversation> {
    const { data: member, error: memberError } = await this.db.from('users').select('id, name, email').eq('id', userId).maybeSingle();
    if (memberError) throw new ServiceUnavailableException('Could not send your message right now.');
    if (!member) throw new BadRequestException('Finish setting up your profile first, then try again.');
    const email = typeof member.email === 'string' ? member.email.trim().toLowerCase() : '';
    const firstLine = firstMessage.split('\n').find((l) => l.trim()) ?? '';
    for (let attempt = 0; attempt < 4; attempt++) {
      const { data, error } = await this.db.from('support_conversations').insert({
        ref: makeRef(),
        label: 'support',
        status: 'open',
        subject: threadSubject(firstLine.length > 80 ? `${firstLine.slice(0, 79).trimEnd()}…` : firstLine),
        contact_email: /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? email : null,
        contact_name: typeof member.name === 'string' && member.name.trim() ? member.name.trim().slice(0, 120) : null,
        user_id: userId,
        started_by: 'member',
        reply_via: 'app',
      }).select(CONVERSATION_COLUMNS).single();
      if (!error) return data as unknown as Conversation;
      if (error.code !== '23505') {
        this.logger.error(`[SUPPORT] could not open an app conversation: ${error.message}`);
        throw new ServiceUnavailableException('Could not send your message right now.');
      }
      // Either another send from this member opened it a moment ago (one thread
      // per member) or the reference was taken: use theirs, or draw again.
      const theirs = await this.appConversation(userId);
      if (theirs) return theirs;
    }
    throw new ServiceUnavailableException('Could not send your message right now.');
  }

  /** A staff-only note. Never sent; does not change the status. */
  async note(id: string, admin: AdminContext, text: string) {
    const body = cleanBody(text);
    await this.conversation(id);
    const { data, error } = await this.db.from('support_messages').insert({
      conversation_id: id,
      author: 'staff',
      admin_id: admin.id,
      internal: true,
      channel: 'note',
      body,
    }).select('id').single();
    if (error) throw new ServiceUnavailableException('Could not save the note right now.');
    return { id: data.id as string };
  }

  async setStatus(id: string, status: string) {
    if (!STATUSES.includes(status as ConversationStatus)) throw new BadRequestException('Unknown status.');
    await this.conversation(id);
    const { error } = await this.db.from('support_conversations').update({ status }).eq('id', id);
    if (error) throw new ServiceUnavailableException('Could not change the status right now.');
    return { id, status };
  }

  /**
   * Write to someone first, by email, from the inbox the admin chose: support@
   * as Help24 Support (default) or security@ as Help24 Security. The thread
   * belongs to that inbox, so the reply and every later message stay there.
   */
  async start(admin: AdminContext, input: { email: string; subject: string; body: string; from?: string }) {
    const email = input.email.trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) || email.endsWith('@help24.co.ke')) {
      throw new BadRequestException('Enter the member\'s email address.');
    }
    const subject = threadSubject(input.subject);
    cleanBody(input.body);
    const conversation = await this.createConversation({
      label: input.from === 'security' ? 'security' : 'support',
      subject,
      contactEmail: email,
      contactName: null,
      startedBy: 'staff',
    });
    const sent = await this.reply(conversation.id, admin, input.body);
    return { conversationId: conversation.id, ...sent };
  }
}

function cleanBody(text: string): string {
  const body = cleanOptionalBody(text);
  if (!body) throw new BadRequestException('Write a message first.');
  return body;
}

/** The words of a message that carries photos: may be empty. */
function cleanOptionalBody(text: string): string {
  const body = (text ?? '').replace(/\r\n?/g, '\n').trim();
  if (body.length > MAX_REPLY) throw new BadRequestException(`Keep it under ${MAX_REPLY} characters.`);
  return body;
}

/** The Inbox list's one-line preview: the words, or what was sent instead. */
function previewOf(m: Row): string {
  const body = typeof m.body === 'string' ? m.body : '';
  if (body.trim()) return body.slice(0, 160);
  const n = Array.isArray(m.attachments) ? m.attachments.length : 0;
  return n === 1 ? 'Photo' : n > 1 ? `${n} photos` : '';
}
