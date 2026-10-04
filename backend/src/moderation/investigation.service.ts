import { Injectable, Logger, NotFoundException } from '@nestjs/common';
import { getAuth } from 'firebase-admin/auth';
import { SupabaseService } from '../supabase/supabase.service';
import { FirebaseAdminService } from '../notifications/firebase-admin.service';
import { AdminContext } from '../admin/auth/admin-role';
import { AuditQueryDto, ListReportsQueryDto, RestrictedQueryDto } from './dto/moderation-admin.dto';
import { OPEN_REPORT_STATUSES, referenceOf } from './moderation.constants';
import { PgError, toHttpError } from './moderation-errors';
import { ReportEvidenceService } from './report-evidence.service';
import { ChatAttachmentLinksService } from './chat-attachment-links.service';

// The Supabase client RETURNS errors rather than throwing them. Every read here
// goes through `must`, so a failed query becomes an error the admin sees —
// never a confident zero or an empty list that reads as "nothing to worry about".
type Row = Record<string, any>;
type Result<T> = { data: T | null; error: PgError | null; count?: number | null };

const DAY_MS = 86_400_000;

const REPORT_LIST_COLUMNS =
  'id, reporter_id, reported_user_id, target_type, target_id, reason, details, status, severity, ' +
  'source, assigned_admin_id, assigned_at, created_at, updated_at, resolved_at, resolution, ' +
  'chat_id, post_id, message_id, application_id, target_snapshot, evidence';

/**
 * Everything an admin READS in Trust & Safety.
 *
 * THE ONE RULE THIS SERVICE KEEPS: an allegation, a fact and a decision are
 * three different things, and nothing here lets one pass for another.
 *
 *   allegation  what a reporter SAID (user_reports, as filed, with the
 *               snapshot of what they were looking at)
 *   platform    what Help24's own tables RECORD (account age, listings, jobs,
 *               payments, disputes, the conversation itself)
 *   decision    what an admin DID (moderation_actions, the ledger)
 *
 * The investigation timeline tags every event with its layer, and the signals
 * are counts and facts — never a score. "Three people reported this account"
 * is a fact; "this account is a scammer" is a conclusion only an admin draws,
 * and only by recording a decision with a reason.
 */
@Injectable()
export class InvestigationService {
  private readonly logger = new Logger(InvestigationService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly evidence: ReportEvidenceService,
    private readonly firebase: FirebaseAdminService,
    private readonly attachments: ChatAttachmentLinksService,
  ) {}

  private get db() {
    return this.supabase.client;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Overview
  // ═══════════════════════════════════════════════════════════════════════════

  async summary(admin: AdminContext) {
    const now = Date.now();
    const since24h = new Date(now - DAY_MS).toISOString();
    const since7d = new Date(now - 7 * DAY_MS).toISOString();
    const openReports = () =>
      this.db.from('user_reports').select('id', { count: 'exact', head: true }).in('status', OPEN_REPORT_STATUSES as string[]);

    const [open, critical, high, unassigned, mine, new24h, suspended, banned, restricted, actions7d] =
      await Promise.all([
        count(openReports()),
        count(openReports().eq('severity', 'critical')),
        count(openReports().eq('severity', 'high')),
        count(openReports().is('assigned_admin_id', null)),
        count(openReports().eq('assigned_admin_id', admin.id)),
        count(this.db.from('user_reports').select('id', { count: 'exact', head: true }).gte('created_at', since24h)),
        count(this.db.from('moderation_account_state').select('user_id', { count: 'exact', head: true }).eq('account_status', 'suspended')),
        count(this.db.from('moderation_account_state').select('user_id', { count: 'exact', head: true }).eq('account_status', 'banned')),
        count(this.db.from('moderation_account_state').select('user_id', { count: 'exact', head: true }).eq('account_status', 'restricted')),
        count(this.db.from('moderation_actions').select('id', { count: 'exact', head: true }).gte('created_at', since7d)),
      ]);

    return {
      open_reports: open,
      critical_open: critical,
      high_open: high,
      unassigned_open: unassigned,
      assigned_to_me: mine,
      reports_last_24h: new24h,
      suspended_accounts: suspended,
      banned_accounts: banned,
      restricted_accounts: restricted,
      actions_last_7d: actions7d,
    };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Reports
  // ═══════════════════════════════════════════════════════════════════════════

  async listReports(f: ListReportsQueryDto, admin: AdminContext) {
    const limit = f.limit ?? 50;
    const offset = f.offset ?? 0;

    let q = this.db.from('user_reports').select(REPORT_LIST_COLUMNS, { count: 'exact' });

    if (f.status === 'open') q = q.in('status', OPEN_REPORT_STATUSES as string[]);
    else if (f.status === 'closed') q = q.in('status', ['resolved', 'dismissed']);
    else if (f.status) q = q.eq('status', f.status);
    if (f.severity) q = q.eq('severity', f.severity);
    if (f.category) q = q.eq('reason', f.category);
    if (f.target_type) q = q.eq('target_type', f.target_type);
    if (f.reported_user_id) q = q.eq('reported_user_id', f.reported_user_id);
    if (f.reporter_id) q = q.eq('reporter_id', f.reporter_id);
    if (f.assigned === 'me') q = q.eq('assigned_admin_id', admin.id);
    else if (f.assigned === 'none') q = q.is('assigned_admin_id', null);
    else if (f.assigned) q = q.eq('assigned_admin_id', f.assigned);
    if (f.from) q = q.gte('created_at', f.from);
    if (f.to) q = q.lte('created_at', f.to);

    if (f.q?.trim()) {
      const search = await this.searchFilter(f.q);
      if (search.kind === 'none') return { total: 0, limit, offset, items: [] };
      if (search.kind === 'ref') q = q.gte('id', search.lo).lte('id', search.hi);
      else q = q.or(search.clause);
    }

    q = f.sort === 'newest'
      ? q.order('created_at', { ascending: false })
      : q.order('severity_rank', { ascending: false }).order('created_at', { ascending: true });

    const { data, count: total } = await must<Row[]>(q.range(offset, offset + limit - 1));
    return { total: total ?? 0, limit, offset, items: await this.decorateReports(data ?? []) };
  }

  async getReport(id: string) {
    const { data: report } = await must<Row>(this.db.from('user_reports').select('*').eq('id', id).maybeSingle());
    if (!report) throw new NotFoundException({ code: 'MODERATION_NOT_FOUND', message: 'Report not found.' });

    const reportedId = report.reported_user_id as string;
    const reporterId = report.reporter_id as string;

    const [people, admins, live, conversation, related, ledger, reported, reporterRecord, job, evidence, snapshotAttachment] =
      await Promise.all([
        this.usersBrief([reporterId, reportedId]),
        this.adminsBrief([report.assigned_admin_id, report.resolved_by]),
        this.liveTarget(report),
        this.conversationFor(report),
        this.relatedReports(report),
        this.ledger({ reportId: id }),
        this.accountSummary(reportedId),
        this.reporterRecord(reporterId),
        this.jobContext(report.post_id as string | null, reportedId),
        this.signEvidence(report.evidence),
        this.snapshotAttachment(report),
      ]);

    return {
      report: {
        ...report,
        reference: referenceOf(id),
        evidence,
        assigned_admin: admins.get(report.assigned_admin_id) ?? null,
        resolved_by_admin: admins.get(report.resolved_by) ?? null,
      },
      reporter: { ...(people.get(reporterId) ?? { id: reporterId }), ...reporterRecord },
      reported: reported,
      target: {
        type: report.target_type,
        id: report.target_id,
        snapshot: report.target_snapshot,
        // The reported message's photo or document AS REPORTED, as a
        // ten-minute signed link. The snapshot's own `attachment_url` is a
        // storage reference, never something to open.
        attachment_view_url: snapshotAttachment,
        live,
        changed_since_report: targetChanged(report.target_type, report.target_snapshot, live),
      },
      conversation,
      job,
      related_reports: related,
      decisions: ledger.filter((a) => a.action_type !== 'note_added'),
      notes: ledger.filter((a) => a.action_type === 'note_added'),
      timeline: this.reportTimeline(report, reported, live, job, related, ledger),
    };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Accounts
  // ═══════════════════════════════════════════════════════════════════════════

  /** The full moderation profile of one account. */
  async getUserProfile(userId: string) {
    const summary = await this.accountSummary(userId);
    if (!summary.user) throw new NotFoundException({ code: 'MODERATION_NOT_FOUND', message: 'Account not found.' });

    const [restrictions, ledger, received, made, posts, applications] = await Promise.all([
      must<Row[]>(this.db.from('account_restrictions').select('*').eq('user_id', userId).order('created_at', { ascending: false }).limit(200)),
      this.ledger({ userId }),
      must<Row[]>(this.db.from('user_reports').select(REPORT_LIST_COLUMNS).eq('reported_user_id', userId).order('created_at', { ascending: false }).limit(50)),
      must<Row[]>(this.db.from('user_reports').select(REPORT_LIST_COLUMNS).eq('reporter_id', userId).order('created_at', { ascending: false }).limit(50)),
      must<Row[]>(this.db.from('posts').select('id, title, type, status, category, price, created_at, archived_at, archived_by, selected_provider_id').eq('author_user_id', userId).order('created_at', { ascending: false }).limit(25)),
      must<Row[]>(this.db.from('applications').select('id, post_id, message, proposed_price, created_at, posts(title, type, author_user_id)').eq('applicant_user_id', userId).order('created_at', { ascending: false }).limit(25)),
    ]);

    const adminIds = (restrictions.data ?? []).flatMap((r) => [r.created_by, r.lifted_by]);
    const admins = await this.adminsBrief(adminIds);

    return {
      ...summary,
      restrictions: (restrictions.data ?? []).map((r) => ({
        ...r,
        reference: referenceOf(r.id),
        active: isActive(r),
        created_by_admin: admins.get(r.created_by) ?? null,
        lifted_by_admin: admins.get(r.lifted_by) ?? null,
      })),
      ledger,
      reports_received: await this.decorateReports(received.data ?? []),
      reports_made: await this.decorateReports(made.data ?? []),
      recent_posts: posts.data ?? [],
      recent_applications: applications.data ?? [],
      timeline: this.accountTimeline(summary, posts.data ?? [], applications.data ?? [], received.data ?? [], ledger),
    };
  }

  async listRestricted(f: RestrictedQueryDto) {
    const now = new Date().toISOString();
    let q = this.db
      .from('account_restrictions')
      .select('id, user_id, kind, reason, starts_at, ends_at, created_at, created_by, created_by_system, report_id')
      .is('lifted_at', null)
      .lte('starts_at', now)
      .or(`ends_at.is.null,ends_at.gt.${now}`)
      .order('created_at', { ascending: false })
      .limit(500);
    if (f.kind) q = q.eq('kind', f.kind);
    const { data } = await must<Row[]>(q);
    const rows = data ?? [];
    const [people, admins] = await Promise.all([
      this.usersBrief(rows.map((r) => r.user_id)),
      this.adminsBrief(rows.map((r) => r.created_by)),
    ]);
    return rows.map((r) => ({
      ...r,
      reference: referenceOf(r.id),
      user: people.get(r.user_id) ?? { id: r.user_id },
      created_by_admin: admins.get(r.created_by) ?? null,
    }));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Audit
  // ═══════════════════════════════════════════════════════════════════════════

  async listAudit(f: AuditQueryDto) {
    const limit = f.limit ?? 50;
    const offset = f.offset ?? 0;
    let q = this.db.from('moderation_actions').select('*', { count: 'exact' });
    if (f.admin_id) q = q.eq('admin_id', f.admin_id);
    if (f.action_type) q = q.eq('action_type', f.action_type);
    if (f.user_id) q = q.eq('target_user_id', f.user_id);
    if (f.report_id) q = q.eq('report_id', f.report_id);
    if (f.from) q = q.gte('created_at', f.from);
    if (f.to) q = q.lte('created_at', f.to);
    if (f.ref) {
      const range = idRange(f.ref);
      q = q.gte('id', range.lo).lte('id', range.hi);
    }
    const { data, count: total } = await must<Row[]>(
      q.order('created_at', { ascending: false }).order('chain_seq', { ascending: false }).range(offset, offset + limit - 1),
    );
    const rows = data ?? [];
    const people = await this.usersBrief(rows.map((r) => r.target_user_id));
    return {
      total: total ?? 0,
      limit,
      offset,
      items: rows.map((r) => ({ ...r, reference: referenceOf(r.id), target_user: people.get(r.target_user_id) ?? { id: r.target_user_id } })),
    };
  }

  /** Recompute the ledger's hash chain (moderation_audit_integrity). */
  async integrity() {
    const bad = (flag: string) =>
      count(this.db.from('moderation_audit_integrity').select('id', { count: 'exact', head: true }).eq(flag, false));
    const [rows, hash, link, seq] = await Promise.all([
      count(this.db.from('moderation_audit_integrity').select('id', { count: 'exact', head: true })),
      bad('hash_ok'),
      bad('link_ok'),
      bad('seq_ok'),
    ]);
    return { rows, edited_rows: hash, broken_links: link, sequence_gaps: seq, intact: hash + link + seq === 0, checked_at: new Date().toISOString() };
  }

  async listAdmins() {
    const { data } = await must<Row[]>(this.db.from('admin_users').select('id, name, email, role').eq('active', true).order('email'));
    return data ?? [];
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Building blocks
  // ═══════════════════════════════════════════════════════════════════════════

  /** Who an account is, its standing, and the deterministic signals about it. */
  private async accountSummary(userId: string) {
    const [{ data: user }, signIn, state, signals] = await Promise.all([
      must<Row>(this.db.from('users')
        .select('id, name, email, phone_number, created_at, last_login, profession, is_verified, role, account_type, avatar_url, profile_image, bio, is_banned')
        .eq('id', userId).maybeSingle()),
      this.signInInfo(userId),
      must<Row[]>(this.db.from('account_restrictions').select('id, kind, reason, starts_at, ends_at, created_at')
        .eq('user_id', userId).is('lifted_at', null)),
      this.signals(userId),
    ]);
    const active = (state.data ?? []).filter(isActive);
    return {
      user: user
        ? {
            ...user,
            phone_number: maskPhone(user.phone_number as string | null),
            avatar: (user.avatar_url as string) || (user.profile_image as string) || null,
          }
        : null,
      sign_in: signIn,
      account: {
        status: active.some((r) => r.kind === 'ban')
          ? 'banned'
          : active.some((r) => r.kind === 'suspension')
            ? 'suspended'
            : active.length > 0 ? 'restricted' : 'active',
        active_restrictions: active.map((r) => ({ ...r, reference: referenceOf(r.id) })),
      },
      signals,
    };
  }

  /**
   * DETERMINISTIC SIGNALS — counts and facts an admin weighs, never a verdict.
   * No score is computed and none should be: a number that looks like a
   * probability invites being treated as one.
   */
  private async signals(userId: string) {
    const [posts, apps, rep, raised, involved, failedPay, cancelled, received, made, actions] = await Promise.all([
      must<Row[]>(this.db.from('posts').select('type, archived_by').eq('author_user_id', userId).limit(2000)),
      count(this.db.from('applications').select('id', { count: 'exact', head: true }).eq('applicant_user_id', userId)),
      must<Row>(this.db.from('provider_reputation')
        .select('completed_jobs, avg_rating, total_reviews, disputed_jobs, open_disputes, completion_rate')
        .eq('provider_id', userId).maybeSingle()),
      count(this.db.from('disputes').select('id', { count: 'exact', head: true }).eq('raised_by_user_id', userId)),
      must<Row[]>(this.db.from('posts').select('id').or(`author_user_id.eq.${userId},selected_provider_id.eq.${userId}`).limit(1000)),
      count(this.db.from('transactions').select('id', { count: 'exact', head: true }).eq('buyer_user_id', userId).eq('status', 'failed')),
      count(this.db.from('posts').select('id', { count: 'exact', head: true }).eq('selected_provider_id', userId).eq('status', 'cancelled')),
      must<Row[]>(this.db.from('user_reports').select('reporter_id, status, resolution, created_at').eq('reported_user_id', userId).limit(2000)),
      must<Row[]>(this.db.from('user_reports').select('status, resolution').eq('reporter_id', userId).limit(2000)),
      must<Row[]>(this.db.from('moderation_actions').select('action_type').eq('target_user_id', userId).limit(5000)),
    ]);

    const involvedIds = (involved.data ?? []).map((p) => p.id as string);
    let disputesAgainst = 0;
    if (involvedIds.length > 0) {
      disputesAgainst = await count(
        this.db.from('disputes').select('id', { count: 'exact', head: true })
          .in('post_id', involvedIds).neq('raised_by_user_id', userId),
      );
    }

    const postRows = posts.data ?? [];
    const receivedRows = received.data ?? [];
    const since30 = Date.now() - 30 * DAY_MS;
    const actionCounts = tally((actions.data ?? []).map((a) => a.action_type as string));

    return {
      requests_created: postRows.filter((p) => p.type === 'request').length,
      offers_created: postRows.filter((p) => p.type === 'offer').length,
      jobs_created: postRows.filter((p) => p.type === 'job').length,
      listings_hidden_by_moderation: postRows.filter((p) => p.archived_by === 'moderation').length,
      applications_made: apps,
      completed_jobs: (rep.data?.completed_jobs as number) ?? 0,
      avg_rating: (rep.data?.avg_rating as number) ?? null,
      total_reviews: (rep.data?.total_reviews as number) ?? 0,
      completion_rate: (rep.data?.completion_rate as number) ?? null,
      disputes_raised: raised,
      disputes_against: disputesAgainst,
      failed_payments: failedPay,
      cancelled_as_provider: cancelled,
      reports_received: receivedRows.length,
      reports_received_open: receivedRows.filter((r) => OPEN_REPORT_STATUSES.includes(r.status)).length,
      reports_received_distinct_reporters: new Set(receivedRows.map((r) => r.reporter_id)).size,
      reports_received_distinct_reporters_30d: new Set(
        receivedRows.filter((r) => Date.parse(r.created_at) >= since30).map((r) => r.reporter_id),
      ).size,
      reports_received_dismissed: receivedRows.filter((r) => r.resolution === 'dismissed').length,
      reports_received_actioned: receivedRows.filter((r) => r.resolution === 'action_taken').length,
      reports_made: (made.data ?? []).length,
      reports_made_dismissed: (made.data ?? []).filter((r) => r.resolution === 'dismissed').length,
      warnings: actionCounts.warning_issued ?? 0,
      suspensions: actionCounts.suspension_applied ?? 0,
      bans: (actionCounts.ban_applied ?? 0) + (actionCounts.legacy_ban_imported ?? 0),
      partial_restrictions: (actionCounts.messaging_restricted ?? 0) + (actionCounts.marketplace_restricted ?? 0),
      content_removals: actionCounts.content_removed ?? 0,
    };
  }

  /** How the account signs in — from Firebase, the only source that knows. */
  private async signInInfo(userId: string) {
    const app = this.firebase.app;
    if (!app) return null;
    try {
      const record = await withTimeout(getAuth(app).getUser(userId), 3_000);
      const providers = record.providerData.map((p) => p.providerId);
      return {
        providers,
        // Firebase phone sign-in proves possession of the number by OTP.
        phone_verified: providers.includes('phone'),
        email_verified: record.emailVerified,
        created_at: record.metadata.creationTime ?? null,
        last_sign_in: record.metadata.lastSignInTime ?? null,
        disabled: record.disabled,
      };
    } catch (e) {
      this.logger.warn(`[INVESTIGATION] sign-in info unavailable for ${userId}: ${(e as Error).message}`);
      return null;
    }
  }

  /** A reporter's own record — how often their reports held up. */
  private async reporterRecord(reporterId: string) {
    const { data } = await must<Row[]>(this.db.from('user_reports').select('status, resolution').eq('reporter_id', reporterId).limit(2000));
    const rows = data ?? [];
    return {
      reports_made: rows.length,
      reports_made_actioned: rows.filter((r) => r.resolution === 'action_taken').length,
      reports_made_dismissed: rows.filter((r) => r.resolution === 'dismissed').length,
    };
  }

  /** The reported thing AS IT IS NOW, to compare against the snapshot. */
  private async liveTarget(report: Row): Promise<Row | null> {
    const id = report.target_id as string;
    switch (report.target_type) {
      case 'user': {
        const { data } = await must<Row>(this.db.from('users').select('id, name, bio, profession, avatar_url, profile_image, created_at').eq('id', id).maybeSingle());
        return data;
      }
      case 'post': {
        const [{ data: post }, { data: images }] = await Promise.all([
          must<Row>(this.db.from('posts')
            .select('id, title, description, type, status, category, location, price, created_at, archived_at, archived_by, author_user_id, selected_provider_id')
            .eq('id', id).maybeSingle()),
          must<Row[]>(this.db.from('post_images').select('image_url').eq('post_id', id).limit(10)),
        ]);
        return post ? { ...post, images: (images ?? []).map((i) => i.image_url) } : null;
      }
      case 'application': {
        const { data } = await must<Row>(this.db.from('applications')
          .select('id, post_id, message, proposed_price, created_at, applicant_user_id, posts(title, type, author_user_id, status)')
          .eq('id', id).maybeSingle());
        return data;
      }
      case 'message': {
        const { data } = await must<Row>(this.db.from('chat_messages')
          .select('id, chat_id, sender_id, content, type, attachment_url, created_at, deleted_for_everyone')
          .eq('id', id).maybeSingle());
        return data ? { ...data, attachment_view_url: await this.attachments.viewUrl(data) } : null;
      }
      default:
        return null;
    }
  }

  /**
   * The conversation between the reporter and the reported account, when there
   * is one. Shown because the reporter is a PARTICIPANT in it — the same basis
   * on which the disputes centre shows a job's chat. Nothing here reads a
   * conversation the reporter was not in.
   */
  private async conversationFor(report: Row) {
    const reporter = report.reporter_id as string;
    const reported = report.reported_user_id as string;
    let chatId = report.chat_id as string | null;

    if (!chatId) {
      const [u1, u2] = reporter < reported ? [reporter, reported] : [reported, reporter];
      let q = this.db.from('chats').select('id, post_id, updated_at').eq('user1', u1).eq('user2', u2);
      if (report.post_id) q = q.eq('post_id', report.post_id);
      const { data } = await must<Row[]>(q.order('updated_at', { ascending: false }).limit(1));
      chatId = (data?.[0]?.id as string) ?? null;
    }
    if (!chatId) return null;

    const { data: chat } = await must<Row>(this.db.from('chats').select('id, user1, user2, post_id').eq('id', chatId).maybeSingle());
    if (!chat || ![chat.user1, chat.user2].includes(reporter)) return null;

    const columns = 'id, sender_id, content, type, attachment_url, created_at, deleted_for_everyone';
    let messages: Row[];
    if (report.target_type === 'message' && report.message_id) {
      const pivot = (report.target_snapshot?.sent_at as string) ?? null;
      const [before, after] = await Promise.all([
        must<Row[]>(this.db.from('chat_messages').select(columns).eq('chat_id', chatId)
          .lte('created_at', pivot ?? new Date().toISOString()).order('created_at', { ascending: false }).limit(25)),
        pivot
          ? must<Row[]>(this.db.from('chat_messages').select(columns).eq('chat_id', chatId)
              .gt('created_at', pivot).order('created_at', { ascending: true }).limit(10))
          : Promise.resolve({ data: [] as Row[], error: null }),
      ]);
      messages = [...(before.data ?? []).reverse(), ...(after.data ?? [])];
    } else {
      const { data } = await must<Row[]>(this.db.from('chat_messages').select(columns).eq('chat_id', chatId)
        .order('created_at', { ascending: false }).limit(50));
      messages = (data ?? []).reverse();
    }

    return {
      chat_id: chatId,
      post_id: chat.post_id ?? null,
      basis: 'The reporter is a participant in this conversation.',
      messages: await Promise.all(messages.map(async (m) => ({
        ...m,
        from: m.sender_id === reported ? 'reported' : m.sender_id === reporter ? 'reporter' : 'other',
        is_reported_message: m.id === report.message_id,
        attachment_view_url: m.attachment_url ? await this.attachments.viewUrl({ ...m, chat_id: chatId }) : null,
      }))),
    };
  }

  /** A signed view link for the attachment the reported message had when it was reported. */
  private async snapshotAttachment(report: Row): Promise<string | null> {
    if (report.target_type !== 'message') return null;
    const snap = (report.target_snapshot ?? {}) as Row;
    if (!snap.attachment_url) return null;
    return this.attachments.viewUrl({
      id: report.message_id ?? report.target_id,
      chat_id: report.chat_id,
      // Migration 114 records the reported message's sender as reported_user_id.
      sender_id: report.reported_user_id,
      type: snap.type,
      attachment_url: snap.attachment_url,
    });
  }

  /** Other reports about the same account: the strongest signal there is. */
  private async relatedReports(report: Row) {
    const { data } = await must<Row[]>(this.db.from('user_reports')
      .select('id, reporter_id, reason, status, severity, resolution, target_type, target_id, target_snapshot, created_at')
      .eq('reported_user_id', report.reported_user_id)
      .neq('id', report.id)
      .order('created_at', { ascending: false })
      .limit(50));
    return (data ?? []).map((r) => ({
      ...r,
      reference: referenceOf(r.id),
      same_target: r.target_type === report.target_type && r.target_id === report.target_id,
      same_reporter: r.reporter_id === report.reporter_id,
      target_label: targetLabel(r.target_type, r.target_snapshot),
    }));
  }

  /** The job, payment and dispute record around the listing a report concerns. */
  private async jobContext(postId: string | null, reportedId: string) {
    if (!postId) return null;
    const [{ data: post }, apps, txs, escrow, completions, disputes] = await Promise.all([
      must<Row>(this.db.from('posts')
        .select('id, title, type, status, price, created_at, author_user_id, selected_provider_id, archived_at, archived_by')
        .eq('id', postId).maybeSingle()),
      must<Row[]>(this.db.from('applications').select('id, applicant_user_id, created_at').eq('post_id', postId).limit(200)),
      must<Row[]>(this.db.from('transactions')
        .select('id, status, amount, fee, total_paid, buyer_user_id, created_at, failure_reason')
        .eq('post_id', postId).order('created_at', { ascending: true }).limit(20)),
      must<Row[]>(this.db.from('escrow').select('id, status, amount, created_at, released_at, provider_id').eq('post_id', postId).limit(5)),
      must<Row[]>(this.db.from('job_completions').select('id, status, created_at, reviewed_at, provider_user_id').eq('post_id', postId).order('created_at', { ascending: true }).limit(20)),
      must<Row[]>(this.db.from('disputes')
        .select('id, status, reason, priority, raised_by_user_id, raised_by_role, created_at, resolved_at')
        .eq('post_id', postId).order('created_at', { ascending: true }).limit(20)),
    ]);
    if (!post) return null;
    const applications = apps.data ?? [];
    const reportedApplication = applications.find((a) => a.applicant_user_id === reportedId) ?? null;
    return {
      post,
      reported_role:
        post.author_user_id === reportedId ? 'client'
          : post.selected_provider_id === reportedId ? 'selected_provider'
            : reportedApplication ? 'applicant' : 'other',
      applications_count: applications.length,
      reported_applied_at: reportedApplication?.created_at ?? null,
      transactions: txs.data ?? [],
      escrow: escrow.data ?? [],
      completions: completions.data ?? [],
      disputes: disputes.data ?? [],
    };
  }

  /** The ledger for a report or an account, newest first. */
  private async ledger(by: { reportId?: string; userId?: string }): Promise<Row[]> {
    let q = this.db.from('moderation_actions').select('*');
    if (by.reportId) q = q.eq('report_id', by.reportId);
    if (by.userId) q = q.eq('target_user_id', by.userId);
    const { data } = await must<Row[]>(q.order('created_at', { ascending: false }).order('chain_seq', { ascending: false }).limit(500));
    return (data ?? []).map((a) => ({ ...a, reference: referenceOf(a.id) }));
  }

  private async signEvidence(items: unknown) {
    const list = Array.isArray(items) ? (items as Row[]) : [];
    return Promise.all(list.map(async (e) => ({ ...e, signed_url: await this.evidence.sign(e.path as string) })));
  }

  private async decorateReports(rows: Row[]) {
    if (rows.length === 0) return [];
    const reportedIds = unique(rows.map((r) => r.reported_user_id as string));
    const [people, admins, states, open] = await Promise.all([
      this.usersBrief(rows.flatMap((r) => [r.reporter_id, r.reported_user_id])),
      this.adminsBrief(rows.map((r) => r.assigned_admin_id)),
      must<Row[]>(this.db.from('moderation_account_state').select('user_id, account_status').in('user_id', reportedIds)),
      must<Row[]>(this.db.from('user_reports').select('reported_user_id, reporter_id')
        .in('reported_user_id', reportedIds).in('status', OPEN_REPORT_STATUSES as string[])),
    ]);
    const stateOf = new Map((states.data ?? []).map((s) => [s.user_id as string, s.account_status as string]));
    const openBy = new Map<string, Set<string>>();
    for (const r of open.data ?? []) {
      const set = openBy.get(r.reported_user_id) ?? new Set<string>();
      set.add(r.reporter_id);
      openBy.set(r.reported_user_id, set);
    }
    return rows.map((r) => ({
      ...r,
      reference: referenceOf(r.id),
      target_label: targetLabel(r.target_type, r.target_snapshot),
      evidence_count: Array.isArray(r.evidence) ? r.evidence.length : 0,
      reporter: people.get(r.reporter_id) ?? { id: r.reporter_id },
      reported: {
        ...(people.get(r.reported_user_id) ?? { id: r.reported_user_id }),
        account_status: stateOf.get(r.reported_user_id) ?? 'active',
        open_reports_from_distinct_people: openBy.get(r.reported_user_id)?.size ?? 0,
      },
      assigned_admin: admins.get(r.assigned_admin_id) ?? null,
    }));
  }

  private async usersBrief(ids: Array<string | null | undefined>): Promise<Map<string, Row>> {
    const list = unique(ids.filter((x): x is string => !!x));
    if (list.length === 0) return new Map();
    const { data } = await must<Row[]>(this.db.from('users').select('id, name, avatar_url, profile_image, created_at').in('id', list));
    return new Map((data ?? []).map((u) => [u.id as string, {
      id: u.id,
      name: (u.name as string)?.trim() || 'Unnamed account',
      avatar: (u.avatar_url as string) || (u.profile_image as string) || null,
      member_since: u.created_at,
    }]));
  }

  private async adminsBrief(ids: Array<string | null | undefined>): Promise<Map<string, Row>> {
    const list = unique(ids.filter((x): x is string => !!x));
    if (list.length === 0) return new Map();
    const { data } = await must<Row[]>(this.db.from('admin_users').select('id, name, email, role').in('id', list));
    return new Map((data ?? []).map((a) => [a.id as string, a]));
  }

  /** Turn free text into a filter the API can run safely. */
  private async searchFilter(raw: string): Promise<
    { kind: 'ref'; lo: string; hi: string } | { kind: 'or'; clause: string } | { kind: 'none' }
  > {
    const term = raw.trim();
    if (/^[0-9a-f]{8}$/i.test(term)) return { kind: 'ref', ...idRange(term) };

    // Only characters that cannot break PostgREST's filter grammar.
    const safe = term.replace(/[^\p{L}\p{N} @._-]/gu, '').trim().slice(0, 60);
    if (!safe) return { kind: 'none' };

    const { data: matches } = await must<Row[]>(this.db.from('users').select('id').ilike('name', `%${safe}%`).limit(25));
    const ids = (matches ?? []).map((u) => u.id as string);
    if (/^[A-Za-z0-9_-]{6,128}$/.test(safe)) ids.push(safe);

    const clauses = [`details.ilike.*${safe}*`];
    if (ids.length > 0) {
      const inList = ids.map((id) => `"${id}"`).join(',');
      clauses.push(`reported_user_id.in.(${inList})`, `reporter_id.in.(${inList})`);
    }
    return { kind: 'or', clause: clauses.join(',') };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Timelines — every event carries the layer it belongs to
  // ═══════════════════════════════════════════════════════════════════════════

  private reportTimeline(report: Row, reported: Row, live: Row | null, job: Row | null, related: Row[], ledger: Row[]) {
    const events: TimelineEvent[] = [];
    const add = (at: unknown, layer: TimelineEvent['layer'], kind: string, label: string, detail?: string) => {
      if (typeof at === 'string' && at) events.push({ at, layer, kind, label, ...(detail ? { detail } : {}) });
    };

    add(reported.user?.created_at, 'platform', 'account_created', 'Reported account created');

    const snap = (report.target_snapshot ?? {}) as Row;
    // A reported listing is also the job context below; post it once.
    if (report.target_type === 'post' && job?.post?.id !== report.target_id) {
      add(snap.created_at, 'platform', 'listing_posted', `Listing posted: ${snap.title ?? ''}`.trim());
    }
    if (report.target_type === 'application') add(snap.applied_at, 'platform', 'application_submitted', 'Application submitted');
    if (report.target_type === 'message') add(snap.sent_at, 'platform', 'message_sent', 'Reported message sent');
    if (live && report.target_type === 'post' && live.archived_at) {
      add(live.archived_at, 'platform', 'listing_hidden', live.archived_by === 'moderation' ? 'Listing hidden by moderation' : 'Listing removed by its owner');
    }

    if (job) {
      add(job.post.created_at, 'platform', 'job_posted', `Listing posted: ${job.post.title}`);
      add(job.reported_applied_at, 'platform', 'applied', 'Reported account applied');
      for (const tx of job.transactions as Row[]) {
        add(tx.created_at, 'platform', 'payment', `Payment ${tx.status} — KES ${Number(tx.total_paid ?? 0).toLocaleString('en-KE')}`);
      }
      for (const e of job.escrow as Row[]) add(e.released_at, 'platform', 'escrow_released', 'Escrow released');
      for (const c of job.completions as Row[]) {
        add(c.created_at, 'platform', 'completion_requested', 'Provider marked the job done');
        if (c.status !== 'pending_approval') add(c.reviewed_at, 'platform', 'completion_reviewed', `Completion ${c.status}`);
      }
      for (const d of job.disputes as Row[]) {
        add(d.created_at, 'platform', 'dispute_opened', `Dispute opened by the ${d.raised_by_role ?? 'party'}`, d.reason);
        add(d.resolved_at, 'platform', 'dispute_resolved', `Dispute ${d.status}`);
      }
    }

    add(report.created_at, 'allegation', 'report_filed', `This report: ${humanise(report.reason)}`);
    for (const r of related) {
      add(r.created_at, 'allegation', 'other_report', `Another report: ${humanise(r.reason)}`, r.same_reporter ? 'Same reporter' : undefined);
    }
    for (const a of ledger) add(a.created_at, 'decision', a.action_type, `${humanise(a.action_type)} — ${a.admin_email ?? 'system'}`, a.reason);

    return events.sort((x, y) => Date.parse(x.at) - Date.parse(y.at));
  }

  private accountTimeline(summary: Row, posts: Row[], applications: Row[], received: Row[], ledger: Row[]) {
    const events: TimelineEvent[] = [];
    const add = (at: unknown, layer: TimelineEvent['layer'], kind: string, label: string, detail?: string) => {
      if (typeof at === 'string' && at) events.push({ at, layer, kind, label, ...(detail ? { detail } : {}) });
    };
    add(summary.user?.created_at, 'platform', 'account_created', 'Account created');
    for (const p of posts) add(p.created_at, 'platform', 'listing_posted', `${humanise(p.type)} posted: ${p.title}`);
    for (const a of applications) add(a.created_at, 'platform', 'applied', `Applied to "${a.posts?.title ?? 'a listing'}"`);
    for (const r of received) add(r.created_at, 'allegation', 'report_received', `Reported: ${humanise(r.reason)}`);
    for (const a of ledger) add(a.created_at, 'decision', a.action_type, `${humanise(a.action_type)} — ${a.admin_email ?? 'system'}`, a.reason);
    return events.sort((x, y) => Date.parse(y.at) - Date.parse(x.at));
  }
}

export interface TimelineEvent {
  at: string;
  layer: 'platform' | 'allegation' | 'decision';
  kind: string;
  label: string;
  detail?: string;
}

// ── helpers ─────────────────────────────────────────────────────────────────

async function must<T>(query: PromiseLike<Result<T>>): Promise<{ data: T | null; count: number | null }> {
  const { data, error, count: n } = await query;
  if (error) throw toHttpError(error);
  return { data, count: n ?? null };
}

async function count(query: PromiseLike<Result<unknown>>): Promise<number> {
  const { count: n } = await must(query);
  return n ?? 0;
}

function unique<T>(xs: T[]): T[] {
  return [...new Set(xs)];
}

function tally(xs: string[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const x of xs) out[x] = (out[x] ?? 0) + 1;
  return out;
}

function isActive(r: Row): boolean {
  const now = Date.now();
  return !r.lifted_at && Date.parse(r.starts_at) <= now && (!r.ends_at || Date.parse(r.ends_at) > now);
}

/** The id range a reference prefix names: `7F3A9C21` → 7f3a9c21-0000-… … 7f3a9c21-ffff-…  */
export function idRange(ref: string): { lo: string; hi: string } {
  const hex = ref.toLowerCase().replace(/[^0-9a-f]/g, '').slice(0, 32);
  const lo = hex.padEnd(32, '0');
  const hi = hex.padEnd(32, 'f');
  const fmt = (h: string) => `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
  return { lo: fmt(lo), hi: fmt(hi) };
}

export function targetLabel(type: string, snapshot: Row | null | undefined): string {
  const s = snapshot ?? {};
  switch (type) {
    case 'post':
      return (s.title as string) || 'A listing';
    case 'message':
      return s.content ? `“${String(s.content).slice(0, 80)}”` : 'A message';
    case 'application':
      return s.post_title ? `Application to “${s.post_title}”` : 'An application';
    case 'user':
      return (s.name as string) || 'An account';
    default:
      return 'Unknown';
  }
}

function targetChanged(type: string, snapshot: Row | null, live: Row | null): boolean | null {
  if (!snapshot) return null;
  if (!live) return true;
  switch (type) {
    case 'post':
      return snapshot.title !== live.title || snapshot.description !== (live.description ?? '').slice(0, 4000) || !!live.archived_at;
    case 'message':
      return snapshot.content !== (live.content ?? '').slice(0, 4000) || !!live.deleted_for_everyone;
    case 'application':
      return snapshot.message !== (live.message ?? '').slice(0, 4000);
    case 'user':
      return snapshot.name !== live.name || (snapshot.bio ?? '') !== (live.bio ?? '').slice(0, 2000);
    default:
      return null;
  }
}

/** `0712 345 678` → `•••• •• 678`: enough to recognise, not enough to reuse. */
function maskPhone(phone: string | null): string | null {
  if (!phone) return null;
  const digits = phone.replace(/\D/g, '');
  if (digits.length < 4) return '••••';
  return `•••• ••${digits.slice(-3)}`;
}

function humanise(s: string | null | undefined): string {
  if (!s) return '';
  const text = s.replace(/_/g, ' ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out after ${ms}ms`)), ms);
    p.then(
      (v) => { clearTimeout(timer); resolve(v); },
      (e) => { clearTimeout(timer); reject(e); },
    );
  });
}
