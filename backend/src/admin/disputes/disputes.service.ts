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

/** Disputes a user may not exceed in a rolling window (anti-spam). */
const RATE_LIMIT_MAX_PER_WINDOW = 5;
const RATE_LIMIT_WINDOW_MS = 24 * 60 * 60 * 1000;

/** Active (non-terminal) statuses — a case is still in play. */
const NON_TERMINAL = ['open', 'reviewing', 'under_review'];
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

    await this.systemMessage(disputeId, `Case assigned to ${admin.name || admin.email} (${admin.role}).`);
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

  listEvidence(disputeId: string) {
    return this.supabase.client
      .from('dispute_evidence')
      .select('id, type, uploader_type, uploaded_by, file_url, content, created_at')
      .eq('dispute_id', disputeId)
      .order('created_at', { ascending: true })
      .then(({ data }) => data ?? []);
  }

  // ── Court thread ────────────────────────────────────────────────────────────

  async postMessage(disputeId: string, message: string, admin: AdminContext) {
    await this.requireDispute(disputeId);
    const { data, error } = await this.supabase.client
      .from('dispute_messages')
      .insert({
        dispute_id: disputeId,
        sender_type: 'admin',
        sender_id: admin.id,
        message,
      })
      .select('id, sender_type, sender_id, message, created_at')
      .single();

    if (error) throw new BadRequestException(error.message);
    await this.touchFirstResponse(disputeId);
    return data;
  }

  listMessages(disputeId: string) {
    return this.supabase.client
      .from('dispute_messages')
      .select('id, sender_type, sender_id, message, created_at')
      .eq('dispute_id', disputeId)
      .order('created_at', { ascending: true })
      .then(({ data }) => data ?? []);
  }

  listDecisions(disputeId: string) {
    return this.supabase.client
      .from('dispute_decisions')
      .select('id, decision_type, admin_id, decided_by_system, provider_amount, client_refund_amount, reasoning, created_at')
      .eq('dispute_id', disputeId)
      .order('created_at', { ascending: true })
      .then(({ data }) => data ?? []);
  }

  // ── Internal helpers (shared with DecisionsService via exports) ─────────────

  /** Append a system entry to the court thread. Best-effort. */
  async systemMessage(disputeId: string, message: string): Promise<void> {
    await this.supabase.client
      .from('dispute_messages')
      .insert({ dispute_id: disputeId, sender_type: 'system', sender_id: null, message });
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
