import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../../supabase/supabase.service';
import { NotificationsService } from '../../notifications/notifications.service';
import { EventsService } from '../../events/events.service';
import { EVENT_TYPES } from '../../events/event.types';
import { AdminContext } from '../auth/admin-role';
import { CreateDisputeDto } from './dto/create-dispute.dto';
import { AddEvidenceDto } from './dto/evidence.dto';
import {
  ParticipantReplyDto,
  RequestUploadUrlsDto,
  SubmitEvidenceDto,
  RequestEvidenceDto,
} from './dto/participant.dto';
import { DisputeStorageService } from './dispute-storage.service';

/** Disputes a user may not exceed in a rolling window (anti-spam). */
const RATE_LIMIT_MAX_PER_WINDOW = 5;
const RATE_LIMIT_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Active (non-terminal) statuses — a case is still in play. Includes the
 *  Phase 3.3 transient evidence sub-states so dedupe/queues treat them as open. */
const NON_TERMINAL = [
  'open',
  'reviewing',
  'under_review',
  'awaiting_client_evidence',
  'awaiting_provider_evidence',
  'awaiting_admin_review',
];
const TERMINAL = ['resolved', 'escalated', 'merged', 'resolved_release', 'resolved_refund', 'resolved_partial'];

/**
 * Orchestration for the Disputes Centre: case creation (user-facing), context
 * assembly, assignment/locking, evidence and the court thread.
 *
 * Financial rulings live in DecisionsService; suggestions in
 * DisputeRecommendationService. This service holds NO payout logic.
 */
@Injectable()
export class DisputesService {
  private readonly logger = new Logger(DisputesService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly events: EventsService,
    private readonly storage: DisputeStorageService,
  ) {}

  // ── Create (user-facing: client or provider) ───────────────────────────────

  /**
   * Raise a dispute. Freezes escrow, sets the job to 'disputed', and opens a
   * case. Handles the spec's edge cases:
   *   • duplicate → returns the existing open case (no second row)
   *   • spam      → rate-limited per raiser
   *   • post-payout → blocked once funds already released (no reversal path)
   */
  async createDispute(dto: CreateDisputeDto): Promise<{ dispute_id: string; deduped: boolean }> {
    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id, selected_provider_id')
      .eq('id', dto.post_id)
      .single();

    if (!post) throw new NotFoundException(`Post ${dto.post_id} not found.`);

    const authorId = post.author_user_id as string;
    const providerId = (post.selected_provider_id as string | null) ?? '';

    // Raiser must be a participant, and the declared role must match.
    const isAuthor = dto.raised_by_user_id === authorId;
    const isProvider = dto.raised_by_user_id === providerId;
    if (!isAuthor && !isProvider) {
      throw new ForbiddenException('Only the client or selected provider may dispute this job.');
    }
    if ((dto.raised_by_role === 'client') !== isAuthor) {
      throw new BadRequestException('raised_by_role does not match your relationship to this job.');
    }

    // Rate limit (anti-spam).
    await this.enforceRateLimit(dto.raised_by_user_id);

    // Dedupe: one active case per post. Return the existing one.
    const { data: existing } = await this.supabase.client
      .from('disputes')
      .select('id')
      .eq('post_id', dto.post_id)
      .in('status', NON_TERMINAL)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (existing) {
      this.logger.log(`[DISPUTES] dedupe: post ${dto.post_id} already has open case ${existing.id as string}`);
      return { dispute_id: existing.id as string, deduped: true };
    }

    // Find the active transaction. Block if funds already left escrow.
    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('id, status, amount')
      .eq('post_id', dto.post_id)
      .in('status', ['paid', 'payout_pending', 'disputed'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!tx) {
      // Either no payment, or already released/refunded — both un-disputable here.
      const { data: released } = await this.supabase.client
        .from('transactions')
        .select('status')
        .eq('post_id', dto.post_id)
        .in('status', ['released', 'refunded'])
        .maybeSingle();
      if (released) {
        throw new ConflictException(
          'Funds for this job have already been settled; a dispute cannot reverse a completed payout.',
        );
      }
      throw new BadRequestException('No active escrow transaction found for this job.');
    }

    const txId = tx.id as string;
    const amount = (tx.amount as number) ?? 0;

    // Freeze escrow + job (idempotent if already disputed).
    await this.freezeForDispute(dto.post_id, txId);

    // Auto-priority from escrow value.
    const priority = this.priorityForAmount(amount);

    const { data: created, error: createErr } = await this.supabase.client
      .from('disputes')
      .insert({
        post_id: dto.post_id,
        transaction_id: txId,
        raised_by_user_id: dto.raised_by_user_id,
        raised_by_role: dto.raised_by_role,
        reason: dto.reason,
        status: 'open',
        priority,
      })
      .select('id')
      .single();

    if (createErr || !created) {
      this.logger.error(`[DISPUTES] create failed: ${createErr?.message ?? 'null'}`);
      throw new BadRequestException('Failed to open dispute.');
    }

    const disputeId = created.id as string;

    await this.systemMessage(disputeId, `Dispute opened by ${dto.raised_by_role}. Escrow frozen pending review.`);

    void this.events.emit({
      type: EVENT_TYPES.DISPUTE_OPENED,
      actorUserId: dto.raised_by_user_id,
      entityType: 'dispute',
      entityId: disputeId,
      payload: {
        post_id: dto.post_id,
        post_title: post.title as string,
        provider_id: providerId,
        client_user_id: authorId,
        dispute_id: disputeId,
        transaction_id: txId,
        priority,
      },
    });

    // Notify both parties + the admin queue.
    await this.notifications.sendMany([
      {
        userId: authorId,
        type: 'dispute_opened',
        title: dto.raised_by_role === 'client' ? 'Dispute Submitted' : 'Dispute Opened',
        body: `A dispute on "${post.title as string}" is now under review. Funds are frozen.`,
        data: { post_id: dto.post_id, dispute_id: disputeId },
      },
      ...(providerId
        ? [{
            userId: providerId,
            type: 'dispute_opened' as const,
            title: dto.raised_by_role === 'provider' ? 'Dispute Submitted' : 'Dispute Opened',
            body: `A dispute on "${post.title as string}" is now under review. Funds are frozen.`,
            data: { post_id: dto.post_id, dispute_id: disputeId },
          }]
        : []),
    ]);

    this.logger.log(`[DISPUTES] opened ${disputeId} post=${dto.post_id} priority=${priority}`);
    return { dispute_id: disputeId, deduped: false };
  }

  // ── List / queues ───────────────────────────────────────────────────────────

  async listOpen(status?: string) {
    let query = this.supabase.client
      .from('disputes')
      .select(`
        id, status, priority, reason, raised_by_role, raised_by_user_id,
        assigned_admin_id, assigned_at, created_at, resolved_at, escalated_at,
        provider_amount, buyer_refund,
        posts(id, title, price, status),
        transactions(id, amount, total_paid, status)
      `)
      .order('created_at', { ascending: true })
      .limit(200);

    query = status ? query.eq('status', status) : query.in('status', NON_TERMINAL);

    const { data, error } = await query;
    if (error) throw new BadRequestException(error.message);

    // Attach a live SLA age (ms since opened) for dashboard timers.
    return (data ?? []).map((d) => ({
      ...d,
      sla_age_ms: Date.now() - new Date(d.created_at as string).getTime(),
    }));
  }

  // ── Full case context (job + payment + parties + evidence + thread) ─────────

  async getCase(disputeId: string) {
    const { data: dispute, error } = await this.supabase.client
      .from('disputes')
      .select(`
        id, status, priority, reason, raised_by_role, raised_by_user_id,
        admin_notes, resolved_by, assigned_admin_id, assigned_at, first_response_at,
        escalated_at, merged_into_dispute_id, provider_amount, buyer_refund,
        created_at, resolved_at,
        posts(id, title, price, author_user_id, selected_provider_id, status, archived_at),
        transactions(id, amount, fee, total_paid, status, mpesa_receipt, created_at),
        job_completions(id, status, provider_note, created_at, reviewed_at)
      `)
      .eq('id', disputeId)
      .single();

    if (error || !dispute) throw new NotFoundException(`Dispute ${disputeId} not found.`);

    const post = dispute.posts as unknown as Record<string, unknown> | null;

    const [buyer, provider, evidence, messages, decisions, assignedAdmin, chatTranscript] =
      await Promise.all([
        post ? this.userBrief(post.author_user_id as string) : null,
        post ? this.userBrief(post.selected_provider_id as string) : null,
        this.listEvidence(disputeId),
        this.listMessages(disputeId),
        this.listDecisions(disputeId),
        dispute.assigned_admin_id
          ? this.adminBrief(dispute.assigned_admin_id as string)
          : null,
        post ? this.recentChat(post.id as string) : [],
      ]);

    return {
      ...dispute,
      sla_age_ms: Date.now() - new Date(dispute.created_at as string).getTime(),
      buyer,
      provider,
      assigned_admin: assignedAdmin,
      evidence,
      messages,
      decisions,
      chat_context: chatTranscript,
    };
  }

  // ── Assignment (case lock) ──────────────────────────────────────────────────

  /**
   * Atomically claim a case. Uses a conditional update so two admins opening the
   * same case cannot both claim it (the second gets 409). super_admin may
   * reassign an already-claimed case (override).
   */
  async assign(disputeId: string, admin: AdminContext): Promise<{ assigned_admin_id: string }> {
    const dispute = await this.requireDispute(disputeId);
    if (TERMINAL.includes(dispute.status as string)) {
      throw new ConflictException('Case is already closed.');
    }

    const currentAssignee = dispute.assigned_admin_id as string | null;
    if (currentAssignee && currentAssignee !== admin.id && admin.role !== 'super_admin') {
      throw new ConflictException('Case is already assigned to another admin.');
    }

    const now = new Date().toISOString();
    let update = this.supabase.client
      .from('disputes')
      .update({
        assigned_admin_id: admin.id,
        assigned_at: now,
        status: dispute.status === 'open' ? 'reviewing' : (dispute.status as string),
        first_response_at: (dispute.first_response_at as string | null) ?? now,
      })
      .eq('id', disputeId);

    // Lock: only succeed if unassigned, unless super_admin overriding.
    if (admin.role !== 'super_admin') {
      update = update.is('assigned_admin_id', null);
    }

    const { data, error } = await update.select('id').maybeSingle();
    if (error) throw new BadRequestException(error.message);
    if (!data) throw new ConflictException('Case was just claimed by another admin.');

    // Participant-facing: no admin name/role. Assignment identity stays in the
    // audit trail (assigned_admin_id) and is shown only in the admin dashboard.
    await this.systemMessage(disputeId, 'Your case is now under review by our support team.');
    this.logger.log(`[DISPUTES] ${disputeId} assigned to ${admin.email}`);
    return { assigned_admin_id: admin.id };
  }

  // ── Evidence ────────────────────────────────────────────────────────────────

  async addEvidence(disputeId: string, dto: AddEvidenceDto, admin: AdminContext) {
    await this.requireDispute(disputeId);

    const needsFile = dto.type === 'image' || dto.type === 'video';
    if (needsFile && !dto.file_url) {
      throw new BadRequestException(`${dto.type} evidence requires file_url.`);
    }
    if (!needsFile && !dto.content) {
      throw new BadRequestException(`${dto.type} evidence requires content.`);
    }

    const { data, error } = await this.supabase.client
      .from('dispute_evidence')
      .insert({
        dispute_id: disputeId,
        uploaded_by: admin.id,
        uploader_type: dto.uploader_type,
        type: dto.type,
        file_url: dto.file_url ?? null,
        content: dto.content ?? null,
      })
      .select('id, type, uploader_type, file_url, content, created_at')
      .single();

    if (error) throw new BadRequestException(error.message);
    await this.touchFirstResponse(disputeId);
    return data;
  }

  async listEvidence(disputeId: string) {
    const { data } = await this.supabase.client
      .from('dispute_evidence')
      .select(
        'id, type, uploader_type, uploaded_by, file_url, content, file_name, ' +
          'mime_type, size_bytes, reviewed_at, reviewed_by, created_at',
      )
      .eq('dispute_id', disputeId)
      .is('hidden_at', null)
      .order('created_at', { ascending: true });
    return this.signEvidence((data ?? []) as unknown as Array<Record<string, unknown>>);
  }

  /** Replace stored object paths with short-TTL signed download URLs (best-effort). */
  private async signEvidence(
    rows: Array<Record<string, unknown>>,
  ): Promise<Array<Record<string, unknown>>> {
    return Promise.all(
      rows.map(async (r) => ({
        ...r,
        file_url: await this.storage.sign((r.file_url as string | null) ?? null),
      })),
    );
  }

  // ── Court thread ────────────────────────────────────────────────────────────

  async postMessage(disputeId: string, message: string, admin: AdminContext, internal = false) {
    const dispute = await this.requireDispute(disputeId);
    const { data, error } = await this.supabase.client
      .from('dispute_messages')
      .insert({
        dispute_id: disputeId,
        sender_type: 'admin',
        sender_id: admin.id,
        message,
        kind: 'text',
        internal,
      })
      .select('id, sender_type, sender_id, message, kind, internal, created_at')
      .single();

    if (error) throw new BadRequestException(error.message);
    await this.touchFirstResponse(disputeId);
    // Internal notes never reach participants; public admin messages notify both.
    if (!internal) {
      const post = await this.postBrief(dispute.post_id as string);
      if (post) await this.notifyThread(post, disputeId, 'admin', message);
    }
    return data;
  }

  /** Admin view: every entry including internal notes (hidden rows excluded). */
  async listMessages(disputeId: string) {
    const { data } = await this.supabase.client
      .from('dispute_messages')
      .select('id, sender_type, sender_id, message, kind, internal, created_at')
      .eq('dispute_id', disputeId)
      .is('hidden_at', null)
      .order('created_at', { ascending: true });
    return data ?? [];
  }

  listDecisions(disputeId: string) {
    return this.supabase.client
      .from('dispute_decisions')
      .select('id, decision_type, admin_id, decided_by_system, provider_amount, client_refund_amount, reasoning, created_at')
      .eq('dispute_id', disputeId)
      .order('created_at', { ascending: true })
      .then(({ data }) => data ?? []);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  PARTICIPANT API (client / provider) — NOT behind the admin guard.
  //  Every method authorizes through assertParticipant(). No duplicated logic.
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * THE single source of participant authorization. Loads the dispute + its post
   * and confirms userId is the client (author) or selected provider. Returns the
   * dispute, post and caller role, or throws 404/403. Mirrors the trusted-but-
   * validated user_id model used by createDispute + jobs.getLifecycle.
   */
  async assertParticipant(
    disputeId: string,
    userId: string,
  ): Promise<{ dispute: Record<string, unknown>; post: Record<string, unknown>; role: 'client' | 'provider' }> {
    if (!userId) throw new BadRequestException('user_id is required.');

    const { data: dispute, error } = await this.supabase.client
      .from('disputes')
      .select(
        'id, status, priority, reason, post_id, transaction_id, raised_by_role, ' +
          'assigned_admin_id, created_at, first_response_at, resolved_at, escalated_at',
      )
      .eq('id', disputeId)
      .single();
    if (error || !dispute) throw new NotFoundException(`Dispute ${disputeId} not found.`);
    const disputeRow = dispute as unknown as Record<string, unknown>;

    const post = await this.postBrief(disputeRow.post_id as string);
    if (!post) throw new NotFoundException('Associated job not found.');

    const authorId = post.author_user_id as string;
    const providerId = (post.selected_provider_id as string | null) ?? '';
    const isClient = userId === authorId;
    const isProvider = providerId !== '' && userId === providerId;
    if (!isClient && !isProvider) {
      throw new ForbiddenException('You are not a participant in this dispute.');
    }
    return { dispute: disputeRow, post, role: isClient ? 'client' : 'provider' };
  }

  /** Participant case view: metadata, status, public thread, signed evidence. */
  async getParticipantThread(disputeId: string, userId: string) {
    const { dispute, post, role } = await this.assertParticipant(disputeId, userId);

    const [messages, evidence, decisions, assignedAdmin] = await Promise.all([
      this.listParticipantMessages(disputeId),
      this.listEvidence(disputeId),
      this.listDecisions(disputeId),
      dispute.assigned_admin_id ? this.adminBrief(dispute.assigned_admin_id as string) : null,
    ]);

    return {
      id: dispute.id,
      status: dispute.status,
      priority: dispute.priority,
      reason: dispute.reason,
      created_at: dispute.created_at,
      first_response_at: dispute.first_response_at,
      resolved_at: dispute.resolved_at,
      escalated_at: dispute.escalated_at,
      post: { id: post.id, title: post.title },
      viewer_role: role,
      // Participants never see the admin's identity — only that the case is under
      // review. The real assignee stays in assigned_admin_id for the dashboard.
      assigned_admin: assignedAdmin ? { name: 'Help24 Support', role: 'support' } : null,
      messages,
      evidence,
      decisions,
    };
  }

  /** Participant posts a text reply to the dispute thread. */
  async participantReply(disputeId: string, dto: ParticipantReplyDto) {
    const { dispute, post, role } = await this.assertParticipant(disputeId, dto.user_id);
    if (TERMINAL.includes(dispute.status as string)) {
      throw new ConflictException('This dispute is closed; you can no longer post messages.');
    }

    const { data, error } = await this.supabase.client
      .from('dispute_messages')
      .insert({ dispute_id: disputeId, sender_type: role, sender_id: dto.user_id, message: dto.message, kind: 'text' })
      .select('id, sender_type, sender_id, message, kind, created_at')
      .single();
    if (error) throw new BadRequestException(error.message);

    await this.notifyThread(post, disputeId, role, dto.message);
    return data;
  }

  /** Issue signed upload URLs for evidence files (validated MIME/count). */
  async issueUploadUrls(disputeId: string, dto: RequestUploadUrlsDto) {
    const { dispute } = await this.assertParticipant(disputeId, dto.user_id);
    if (TERMINAL.includes(dispute.status as string)) {
      throw new ConflictException('This dispute is closed; evidence can no longer be added.');
    }
    const files = await this.storage.issueUploadUrls(disputeId, dto.files);
    return { bucket: DisputeStorageService.BUCKET, files };
  }

  /** Register uploaded objects as evidence; advances state + notifies. */
  async submitEvidence(disputeId: string, dto: SubmitEvidenceDto) {
    const { dispute, post, role } = await this.assertParticipant(disputeId, dto.user_id);
    if (TERMINAL.includes(dispute.status as string)) {
      throw new ConflictException('This dispute is closed; evidence can no longer be added.');
    }

    const rows = dto.items.map((it) => {
      DisputeStorageService.assertPathBelongs(disputeId, it.path);
      const type = DisputeStorageService.evidenceTypeFor(it.mime_type);
      if (it.size_bytes != null && it.size_bytes > DisputeStorageService.MAX_FILE_BYTES) {
        throw new BadRequestException(`"${it.file_name}" exceeds the 10MB limit.`);
      }
      return {
        dispute_id: disputeId,
        uploaded_by: dto.user_id,
        uploader_type: role,
        type,
        file_url: it.path, // stored as a PATH; signed on read
        content: it.caption ?? null,
        file_name: it.file_name,
        mime_type: it.mime_type,
        size_bytes: it.size_bytes ?? null,
      };
    });

    const { data: inserted, error } = await this.supabase.client
      .from('dispute_evidence')
      .insert(rows)
      .select(
        'id, type, uploader_type, uploaded_by, file_url, content, file_name, ' +
          'mime_type, size_bytes, reviewed_at, created_at',
      );
    if (error) throw new BadRequestException(error.message);

    // Timeline entry (kind classifies it for lifecycle rendering later).
    const n = rows.length;
    await this.threadEntry(
      disputeId,
      'system',
      'evidence_submitted',
      `${role === 'client' ? 'Client' : 'Provider'} submitted ${n} evidence file${n > 1 ? 's' : ''}.`,
    );

    // A party answered an evidence request → hand the case back to the admin.
    await this.advanceAfterEvidence(disputeId, dispute.status as string);

    await this.notifyEvidenceUploaded(post, disputeId, role);
    return this.signEvidence((inserted ?? []) as unknown as Array<Record<string, unknown>>);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  ADMIN evidence orchestration (called from the guarded DisputesController).
  // ══════════════════════════════════════════════════════════════════════════

  /** Admin requests more evidence from a party; sets awaiting_*_evidence + notifies. */
  async requestEvidence(disputeId: string, dto: RequestEvidenceDto, admin: AdminContext) {
    const dispute = await this.requireDispute(disputeId);
    if (TERMINAL.includes(dispute.status as string)) {
      throw new ConflictException('This dispute is closed.');
    }
    const assignee = dispute.assigned_admin_id as string | null;
    if (assignee && assignee !== admin.id && admin.role !== 'super_admin') {
      throw new ConflictException('Case is assigned to another admin.');
    }

    const post = await this.postBrief(dispute.post_id as string);
    if (!post) throw new NotFoundException('Associated job not found.');

    const targetId =
      dto.from === 'client'
        ? (post.author_user_id as string)
        : ((post.selected_provider_id as string | null) ?? '');
    if (!targetId) {
      throw new BadRequestException(`This job has no ${dto.from} to request evidence from.`);
    }

    // Admin-authored thread entry, classified as an evidence request.
    await this.threadEntry(disputeId, 'admin', 'evidence_request', dto.message, admin.id);

    const newStatus =
      dto.from === 'client' ? 'awaiting_client_evidence' : 'awaiting_provider_evidence';
    await this.supabase.client
      .from('disputes')
      .update({
        status: newStatus,
        first_response_at: (dispute.first_response_at as string | null) ?? new Date().toISOString(),
      })
      .eq('id', disputeId);

    await this.notifications.send({
      userId: targetId,
      type: 'dispute_evidence_requested',
      title: 'Evidence requested',
      body: `Support requested more evidence for "${post.title as string}". ${dto.message}`.slice(0, 180),
      data: { dispute_id: disputeId, post_id: post.id as string },
    });

    this.logger.log(`[DISPUTES] ${disputeId} → ${newStatus} (evidence requested from ${dto.from})`);
    return { ok: true, status: newStatus };
  }

  /** Admin marks an evidence row reviewed (review tracking). */
  async markEvidenceReviewed(disputeId: string, evidenceId: string, admin: AdminContext) {
    await this.requireDispute(disputeId);
    const { data, error } = await this.supabase.client
      .from('dispute_evidence')
      .update({ reviewed_at: new Date().toISOString(), reviewed_by: admin.id })
      .eq('id', evidenceId)
      .eq('dispute_id', disputeId)
      .select('id, reviewed_at, reviewed_by')
      .single();
    if (error || !data) throw new NotFoundException('Evidence not found for this dispute.');
    return data;
  }

  // ── Participant/notification helpers ────────────────────────────────────────

  /** Public thread only: drops internal admin notes and soft-hidden rows. */
  private async listParticipantMessages(disputeId: string) {
    const { data } = await this.supabase.client
      .from('dispute_messages')
      .select('id, sender_type, sender_id, message, kind, created_at')
      .eq('dispute_id', disputeId)
      .eq('internal', false)
      .is('hidden_at', null)
      .order('created_at', { ascending: true });
    return data ?? [];
  }

  /** Insert a classified thread entry (used for evidence_request / evidence_submitted). */
  private async threadEntry(
    disputeId: string,
    senderType: 'client' | 'provider' | 'admin' | 'system',
    kind: 'text' | 'evidence_request' | 'evidence_submitted' | 'system' | 'resolution',
    message: string,
    senderId: string | null = null,
  ): Promise<void> {
    await this.supabase.client
      .from('dispute_messages')
      .insert({ dispute_id: disputeId, sender_type: senderType, sender_id: senderId, message, kind });
  }

  /** From an awaiting_*_evidence state, advance to awaiting_admin_review. */
  private async advanceAfterEvidence(disputeId: string, currentStatus: string): Promise<void> {
    if (currentStatus === 'awaiting_client_evidence' || currentStatus === 'awaiting_provider_evidence') {
      await this.supabase.client
        .from('disputes')
        .update({ status: 'awaiting_admin_review' })
        .eq('id', disputeId);
    }
  }

  /** Notify the relevant participants of a new thread message (dispute_message). */
  private async notifyThread(
    post: Record<string, unknown>,
    disputeId: string,
    senderRole: 'client' | 'provider' | 'admin',
    preview: string,
  ): Promise<void> {
    const authorId = post.author_user_id as string;
    const providerId = (post.selected_provider_id as string | null) ?? '';
    const recipients =
      senderRole === 'admin'
        ? [authorId, providerId]
        : senderRole === 'client'
          ? [providerId]
          : [authorId];
    const who = senderRole === 'admin' ? 'Support' : senderRole === 'client' ? 'The client' : 'The provider';
    const body = preview.length > 90 ? `${preview.slice(0, 87)}…` : preview;

    await this.notifications.sendMany(
      recipients
        .filter((uid) => uid && uid.length > 0)
        .map((uid) => ({
          userId: uid,
          type: 'dispute_message' as const,
          title: 'New dispute message',
          body: `${who}: ${body}`,
          data: { dispute_id: disputeId, post_id: post.id as string },
        })),
    );
  }

  /** Notify the OTHER party that evidence was uploaded (dispute_evidence_uploaded). */
  private async notifyEvidenceUploaded(
    post: Record<string, unknown>,
    disputeId: string,
    uploaderRole: 'client' | 'provider',
  ): Promise<void> {
    const authorId = post.author_user_id as string;
    const providerId = (post.selected_provider_id as string | null) ?? '';
    const otherParty = uploaderRole === 'client' ? providerId : authorId;
    if (!otherParty) return;
    await this.notifications.send({
      userId: otherParty,
      type: 'dispute_evidence_uploaded',
      title: 'New evidence submitted',
      body: `New evidence was added to the dispute on "${post.title as string}".`,
      data: { dispute_id: disputeId, post_id: post.id as string },
    });
  }

  // ── Internal helpers (shared with DecisionsService via exports) ─────────────

  /** Append a system entry to the court thread. Best-effort. */
  async systemMessage(disputeId: string, message: string): Promise<void> {
    await this.supabase.client
      .from('dispute_messages')
      .insert({ dispute_id: disputeId, sender_type: 'system', sender_id: null, message, kind: 'system' });
  }

  /** Load a dispute or 404. */
  async requireDispute(disputeId: string): Promise<Record<string, unknown>> {
    const { data, error } = await this.supabase.client
      .from('disputes')
      .select('id, status, post_id, transaction_id, assigned_admin_id, first_response_at, priority')
      .eq('id', disputeId)
      .single();
    if (error || !data) throw new NotFoundException(`Dispute ${disputeId} not found.`);
    return data;
  }

  private async freezeForDispute(postId: string, txId: string): Promise<void> {
    await Promise.all([
      this.supabase.client.from('transactions').update({ status: 'disputed' }).eq('id', txId),
      this.supabase.client.from('escrow').update({ status: 'disputed' }).eq('transaction_id', txId),
      this.supabase.client.from('posts').update({ status: 'disputed' }).eq('id', postId),
      this.supabase.client
        .from('job_completions')
        .update({ status: 'disputed', reviewed_at: new Date().toISOString() })
        .eq('post_id', postId)
        .eq('status', 'pending_approval'),
    ]);
    void this.events.emit({
      type: EVENT_TYPES.ESCROW_DISPUTED,
      entityType: 'escrow',
      entityId: txId,
      payload: { post_id: postId, transaction_id: txId },
    });
  }

  private async enforceRateLimit(userId: string): Promise<void> {
    const since = new Date(Date.now() - RATE_LIMIT_WINDOW_MS).toISOString();
    const { count } = await this.supabase.client
      .from('disputes')
      .select('*', { count: 'exact', head: true })
      .eq('raised_by_user_id', userId)
      .gte('created_at', since);
    if ((count ?? 0) >= RATE_LIMIT_MAX_PER_WINDOW) {
      throw new ConflictException('Too many disputes raised recently. Please contact support.');
    }
  }

  private priorityForAmount(amount: number): 'low' | 'medium' | 'high' | 'critical' {
    if (amount > 30_000) return 'critical';
    if (amount > 15_000) return 'high';
    if (amount > 5_000) return 'medium';
    return 'low';
  }

  /** Stamp first_response_at on the first admin action (SLA metric). */
  private async touchFirstResponse(disputeId: string): Promise<void> {
    await this.supabase.client
      .from('disputes')
      .update({ first_response_at: new Date().toISOString() })
      .eq('id', disputeId)
      .is('first_response_at', null);
  }

  private async userBrief(userId?: string | null) {
    if (!userId) return null;
    const { data } = await this.supabase.client
      .from('users')
      .select('id, name, phone_number')
      .eq('id', userId)
      .maybeSingle();
    return data;
  }

  /** Minimal post record used for participant auth + thread notifications. */
  private async postBrief(postId: string): Promise<Record<string, unknown> | null> {
    const { data } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id, selected_provider_id')
      .eq('id', postId)
      .single();
    return data ?? null;
  }

  private async adminBrief(adminId: string) {
    const { data } = await this.supabase.client
      .from('admin_users')
      .select('id, name, email, role')
      .eq('id', adminId)
      .maybeSingle();
    return data;
  }

  /** Last 50 chat messages for the post, attached as case context. */
  private async recentChat(postId: string) {
    const { data: chat } = await this.supabase.client
      .from('chats')
      .select('id')
      .eq('post_id', postId)
      .maybeSingle();
    if (!chat) return [];
    const { data } = await this.supabase.client
      .from('chat_messages')
      .select('id, sender_id, content, type, created_at')
      .eq('chat_id', chat.id as string)
      .order('created_at', { ascending: true })
      .limit(50);
    return data ?? [];
  }
}
