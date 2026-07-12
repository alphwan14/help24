import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { EventsService } from '../events/events.service';
import { EVENT_TYPES } from '../events/event.types';
import { MarkCompleteDto } from './dto/mark-complete.dto';
import { ApproveDto } from './dto/client-decision.dto';
import { SelectProviderDto } from './dto/select-provider.dto';
import { deriveSettlementState } from './settlement-state';

@Injectable()
export class JobsService {
  private readonly logger = new Logger(JobsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly events: EventsService,
  ) {}

  // ── Client: select a provider ─────────────────────────────────────────────

  async selectProvider(dto: SelectProviderDto): Promise<{ post_id: string; provider_id: string }> {
    this.logger.log(
      `[JOBS][SELECT_PROVIDER] postId=${dto.post_id} providerId=${dto.provider_id} clientUserId=${dto.client_user_id}`,
    );

    // 1. Validate post exists and caller is the owner.
    const { data: post, error: postErr } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id, selected_provider_id, status')
      .eq('id', dto.post_id)
      .single();

    if (postErr || !post) {
      this.logger.warn(`[JOBS][SELECT_PROVIDER] Post not found: ${dto.post_id}`);
      throw new NotFoundException(`Post ${dto.post_id} not found.`);
    }

    if (post.author_user_id !== dto.client_user_id) {
      this.logger.warn(
        `[JOBS][SELECT_PROVIDER] Forbidden: caller ${dto.client_user_id} is not author ${post.author_user_id as string}`,
      );
      throw new ForbiddenException('Only the post author can select a provider.');
    }

    if (post.status !== 'open') {
      this.logger.warn(
        `[JOBS][SELECT_PROVIDER] Post ${dto.post_id} is not open (status=${post.status as string})`,
      );
      throw new ConflictException(`Cannot select a provider — post status is '${post.status as string}'.`);
    }

    // 2. Validate the provider has actually applied to this post.
    const { data: application } = await this.supabase.client
      .from('applications')
      .select('id')
      .eq('post_id', dto.post_id)
      .eq('applicant_user_id', dto.provider_id)
      .maybeSingle();

    if (!application) {
      this.logger.warn(
        `[JOBS][SELECT_PROVIDER] Provider ${dto.provider_id} has no application on post ${dto.post_id}`,
      );
      throw new BadRequestException('The selected provider has not applied to this post.');
    }

    // 3. Update post: assign provider and mark as assigned.
    const { error: updateErr } = await this.supabase.client
      .from('posts')
      .update({ selected_provider_id: dto.provider_id, status: 'assigned' })
      .eq('id', dto.post_id);

    if (updateErr) {
      this.logger.error(`[JOBS][SELECT_PROVIDER] Failed to update post: ${updateErr.message}`);
      throw new BadRequestException('Failed to assign provider to post.');
    }

    // 4. Emit event — EventProcessorService handles downstream side effects.
    void this.events.emit({
      type: EVENT_TYPES.POST_PROVIDER_SELECTED,
      actorUserId: dto.client_user_id,
      entityType: 'post',
      entityId: dto.post_id,
      payload: {
        post_id:    dto.post_id,
        post_title: post.title as string,
        provider_id: dto.provider_id,
        client_user_id: dto.client_user_id,
      },
    });

    // 5. Notify the provider immediately.
    this.logger.log(`[PROVIDER_SELECTED][START] postId=${dto.post_id} providerId=${dto.provider_id}`);

    // Ensure a chat exists between client and provider for deep-link routing.
    // A chat may not yet exist if the client selected the provider without chatting first.
    let { data: selChatRow } = await this.supabase.client
      .from('chats')
      .select('id')
      .eq('post_id', dto.post_id)
      .or(`user1.eq.${dto.provider_id},user2.eq.${dto.provider_id}`)
      .maybeSingle();

    if (!selChatRow) {
      // Create chat so the "you've been selected" tap always lands in a real conversation.
      this.logger.log(`[PROVIDER_SELECTED][CHAT_CREATE] no existing chat — creating post=${dto.post_id}`);
      const { data: newChat, error: chatErr } = await this.supabase.client
        .from('chats')
        .insert({ post_id: dto.post_id, user1: dto.client_user_id, user2: dto.provider_id })
        .select('id')
        .maybeSingle();
      if (chatErr) {
        this.logger.warn(`[PROVIDER_SELECTED][CHAT_CREATE] failed: ${chatErr.message} — notification sent without chat_id`);
      } else {
        selChatRow = newChat;
        this.logger.log(`[PROVIDER_SELECTED][CHAT_CREATE] created chatId=${newChat?.id as string}`);
      }
    }

    const selChatId = (selChatRow?.id as string | null) ?? '';
    this.logger.log(`[PROVIDER_SELECTED][DB_INSERT] chatId=${selChatId || 'none'} providerId=${dto.provider_id}`);
    await this.notifications.send({
      userId: dto.provider_id,
      type: 'provider_selected',
      title: 'You\'ve been selected!',
      body: `The client selected you for "${post.title as string}". They will now secure payment to begin the job.`,
      data: { post_id: dto.post_id, ...(selChatId ? { chat_id: selChatId } : {}) },
    });
    this.logger.log(`[PROVIDER_SELECTED][PUSH_SENT] provider=${dto.provider_id} chatId=${selChatId || 'none'}`);
    this.logger.log(`[PROVIDER_SELECTED][SUCCESS] post=${dto.post_id}`);

    this.logger.log(
      `[JOBS][SELECT_PROVIDER] SUCCESS postId=${dto.post_id} providerId=${dto.provider_id}`,
    );
    return { post_id: dto.post_id, provider_id: dto.provider_id };
  }

  // ── Provider: mark job as done ─────────────────────────────────────────────

  async markComplete(dto: MarkCompleteDto): Promise<{ completion_id: string }> {
    this.logger.log(`[JOBS] markComplete post=${dto.post_id} provider=${dto.provider_user_id}`);

    const { data: post, error: postErr } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id, selected_provider_id, status')
      .eq('id', dto.post_id)
      .single();

    if (postErr || !post) throw new NotFoundException(`Post ${dto.post_id} not found.`);

    if (post.selected_provider_id !== dto.provider_user_id) {
      throw new ForbiddenException('Only the selected provider can mark this job as done.');
    }

    if (post.status === 'completed' || post.status === 'disputed') {
      throw new ConflictException(`Post is already in status '${post.status as string}'.`);
    }

    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('id, amount, status')
      .eq('post_id', dto.post_id)
      .eq('status', 'paid')
      .maybeSingle();

    if (!tx) {
      throw new BadRequestException('Payment has not been confirmed for this job yet.');
    }

    const { data: existing } = await this.supabase.client
      .from('job_completions')
      .select('id, status')
      .eq('post_id', dto.post_id)
      .eq('status', 'pending_approval')
      .maybeSingle();

    if (existing) {
      throw new ConflictException('A completion request is already pending client approval.');
    }

    const { data: completion, error: compErr } = await this.supabase.client
      .from('job_completions')
      .insert({
        post_id: dto.post_id,
        transaction_id: tx.id,
        provider_user_id: dto.provider_user_id,
        client_user_id: post.author_user_id as string,
        provider_note: dto.provider_note ?? null,
        status: 'pending_approval',
      })
      .select('id')
      .single();

    if (compErr || !completion) {
      this.logger.error(`[JOBS] Failed to create completion: ${compErr?.message ?? 'null'}`);
      throw new BadRequestException('Failed to submit completion request.');
    }

    const completionId = completion.id as string;

    // Emit event — EventProcessorService notifies the client (retryable).
    void this.events.emit({
      type: EVENT_TYPES.JOB_COMPLETION_REQUESTED,
      actorUserId: dto.provider_user_id,
      entityType: 'job_completion',
      entityId: completionId,
      payload: {
        post_id:        dto.post_id,
        completion_id:  completionId,
        post_title:     post.title as string,
        client_user_id: post.author_user_id as string,
        provider_id:    dto.provider_user_id,
      },
    });

    // Also notify inline as fast path.
    const { data: cmpChatRow } = await this.supabase.client
      .from('chats')
      .select('id')
      .eq('post_id', dto.post_id)
      .or(`user1.eq.${dto.provider_user_id},user2.eq.${dto.provider_user_id}`)
      .maybeSingle();
    const cmpChatId = (cmpChatRow?.id as string | null) ?? '';
    this.logger.log(`[JOB_COMPLETE][NOTIFY] notifying client=${post.author_user_id as string} post=${dto.post_id} chatId=${cmpChatId || 'none'}`);
    await this.notifications.send({
      userId: post.author_user_id as string,
      type: 'completion_requested',
      title: 'Job Marked as Done',
      body: `Your provider has marked "${post.title as string}" as complete. Review and approve or dispute.`,
      data: { post_id: dto.post_id, completion_id: completionId, ...(cmpChatId ? { chat_id: cmpChatId } : {}) },
    });
    this.logger.log(`[JOB_COMPLETE][PUSH] sent to client=${post.author_user_id as string}`);

    this.logger.log(`[JOBS] Completion ${completionId} created for post ${dto.post_id}`);
    return { completion_id: completionId };
  }

  // ── Client: approve completion → trigger payout ────────────────────────────
  //
  // KEY CHANGE from previous version:
  // Previously: approve() called mpesa.releasePayout() synchronously → blocked the HTTP
  //             request and threw 400 to the client if Daraja B2C timed out.
  // Now:        approve() emits payment.payout_requested → EventProcessorService
  //             calls releasePayout() in the background → retries if Daraja is slow.
  //             The client immediately gets a 200 response.

  async approve(dto: ApproveDto): Promise<{ message: string }> {
    this.logger.log(`[JOBS] approve post=${dto.post_id} client=${dto.client_user_id}`);

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id, selected_provider_id')
      .eq('id', dto.post_id)
      .single();

    if (!post) throw new NotFoundException(`Post ${dto.post_id} not found.`);

    if (post.author_user_id !== dto.client_user_id) {
      throw new ForbiddenException('Only the post author can approve completion.');
    }

    const completion = await this.getPendingCompletion(dto.post_id);

    await this.supabase.client
      .from('job_completions')
      .update({ status: 'approved', reviewed_at: new Date().toISOString() })
      .eq('id', completion.id);

    await this.supabase.client
      .from('posts')
      .update({ status: 'completed' })
      .eq('id', dto.post_id);

    // Emit job.approved — EventProcessorService handles:
    //   1. Calls releasePayout() (decoupled from this HTTP request)
    //   2. Notifies both parties
    // If payout fails, the event stays processed=false and retries every 60 s.
    void this.events.emit({
      type: EVENT_TYPES.JOB_APPROVED,
      actorUserId: dto.client_user_id,
      entityType: 'job_completion',
      entityId: completion.id as string,
      payload: {
        post_id:     dto.post_id,
        post_title:  post.title as string,
        provider_id: post.selected_provider_id as string,
        buyer_id:    dto.client_user_id,
      },
    });

    // Notify both parties inline for speed.
    const { data: apvChatRow } = await this.supabase.client
      .from('chats')
      .select('id')
      .eq('post_id', dto.post_id)
      .or(`user1.eq.${post.selected_provider_id as string},user2.eq.${post.selected_provider_id as string}`)
      .maybeSingle();
    const apvChatId = (apvChatRow?.id as string | null) ?? '';
    this.logger.log(`[PAYOUT_RELEASED][NOTIFY] notifying provider=${post.selected_provider_id as string} post=${dto.post_id} chatId=${apvChatId || 'none'}`);
    await this.notifications.sendMany([
      {
        userId: post.selected_provider_id as string,
        type: 'payout_released',
        title: 'Payout Initiated!',
        body: `The client approved "${post.title as string}". Your M-Pesa payout is being processed.`,
        data: { post_id: dto.post_id, ...(apvChatId ? { chat_id: apvChatId } : {}) },
      },
      {
        userId: dto.client_user_id,
        type: 'job_approved',
        title: 'Job Approved',
        body: `You approved "${post.title as string}". The provider's payout has been initiated.`,
        data: { post_id: dto.post_id, ...(apvChatId ? { chat_id: apvChatId } : {}) },
      },
      // Review prompt to the client — one of three review entry points (the
      // others are the approval success screen + the lifecycle "Leave Review"
      // button). Routed to the review submission screen by post_id.
      {
        userId: dto.client_user_id,
        type: 'review_requested',
        title: 'Rate your experience',
        body: `How was "${post.title as string}"? Leave a review for the provider.`,
        data: { post_id: dto.post_id },
      },
    ]);
    this.logger.log(`[PAYOUT_RELEASED][PUSH] sent to provider=${post.selected_provider_id as string} and client=${dto.client_user_id}`);

    this.logger.log(`[JOBS] Post ${dto.post_id} approved — payout queued via event.`);
    return { message: 'Job approved. Payout is being processed.' };
  }

  // ── Client: open dispute → REMOVED (Sprint 1, Phase 1.5) ───────────────────
  //
  // The legacy jobs.service.dispute() was a second writer of the 'disputed'
  // lifecycle state (posts/transactions/escrow/job_completions + a thin disputes
  // row), parallel to the canonical DisputesService.createDispute(). It bypassed
  // dedupe, anti-spam, post-payout guards, auto-priority and the court thread.
  // It has been deleted so the 'disputed' state has exactly one authoritative
  // writer. The legacy POST /jobs/dispute route now returns 410 Gone (see
  // jobs.controller.ts); clients raise disputes via POST /disputes/create.

  // ── Notify post author when a provider applies ─────────────────────────────

  async notifyApplication(dto: { post_id: string; applicant_user_id: string }): Promise<void> {
    this.logger.log(
      `[APPLICATION_NOTIFY][START] postId=${dto.post_id} applicantId=${dto.applicant_user_id}`,
    );

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id')
      .eq('id', dto.post_id)
      .maybeSingle();

    if (!post) {
      this.logger.warn(`[APPLICATION_NOTIFY][START] post not found postId=${dto.post_id}`);
      return;
    }

    const authorId = post.author_user_id as string;
    if (!authorId || authorId === dto.applicant_user_id) {
      this.logger.warn(
        `[APPLICATION_NOTIFY][START] skipping — authorId=${authorId} applicantId=${dto.applicant_user_id}`,
      );
      return;
    }

    const { data: applicant } = await this.supabase.client
      .from('users')
      .select('name')
      .eq('id', dto.applicant_user_id)
      .maybeSingle();

    const applicantName = (applicant?.name as string | null) ?? 'Someone';

    this.logger.log(`[APPLICATION_NOTIFY][DB_INSERT] authorId=${authorId} applicantName=${applicantName}`);
    await this.notifications.send({
      userId: authorId,
      type: 'provider_applied',
      title: 'New Application',
      body: `${applicantName} applied to "${post.title as string}". Review their application.`,
      data: { post_id: dto.post_id, applicant_user_id: dto.applicant_user_id },
    });
    this.logger.log(
      `[APPLICATION_NOTIFY][PUSH_SENT] authorId=${authorId} postId=${dto.post_id}`,
    );
    this.logger.log(`[APPLICATION_NOTIFY][REALTIME] notification persisted + push fired for authorId=${authorId}`);
  }

  // ── Status: get job completion state for a post ────────────────────────────

  async getJobStatus(postId: string) {
    const { data } = await this.supabase.client
      .from('job_completions')
      .select('id, status, provider_note, created_at, reviewed_at')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    return data ?? null;
  }

  // ── Lifecycle: participant-scoped aggregate (Job Lifecycle Detail screen) ───
  //
  // Single source of truth for the mobile lifecycle view. Reads the post,
  // payment/escrow, completion and dispute (+ immutable decision ledger) live
  // from the canonical tables and derives a chronological timeline from their
  // timestamps. No lifecycle state is duplicated. Only a participant — the post
  // author (client) or the selected provider — may read it.
  async getLifecycle(postId: string, userId: string) {
    if (!userId) throw new BadRequestException('user_id is required.');

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, title, price, status, author_user_id, selected_provider_id, created_at')
      .eq('id', postId)
      .single();
    if (!post) throw new NotFoundException(`Post ${postId} not found.`);

    const authorId = post.author_user_id as string;
    const providerId = (post.selected_provider_id as string | null) ?? '';
    const isClient = userId === authorId;
    const isProvider = providerId !== '' && userId === providerId;
    if (!isClient && !isProvider) {
      throw new ForbiddenException('Only the client or selected provider can view this job lifecycle.');
    }

    // Latest transaction + its escrow row.
    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('id, status, amount, fee, total_paid, mpesa_receipt, failure_reason, created_at')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    let escrow: Record<string, unknown> | null = null;
    if (tx) {
      const { data: esc } = await this.supabase.client
        .from('escrow')
        .select('status, released_at, created_at')
        .eq('transaction_id', tx.id as string)
        .maybeSingle();
      escrow = esc ?? null;
    }

    // Latest completion request.
    const { data: completion } = await this.supabase.client
      .from('job_completions')
      .select('id, status, provider_note, created_at, reviewed_at')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    // Latest dispute + its immutable decision ledger.
    const { data: disputeRow } = await this.supabase.client
      .from('disputes')
      .select(
        'id, status, priority, reason, raised_by_role, provider_amount, buyer_refund, ' +
          'created_at, first_response_at, escalated_at, resolved_at',
      )
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    const dispute = (disputeRow as unknown as Record<string, unknown> | null) ?? null;

    let decisions: Array<Record<string, unknown>> = [];
    let disputeMessages: Array<Record<string, unknown>> = [];
    if (dispute) {
      const { data: decs } = await this.supabase.client
        .from('dispute_decisions')
        .select('decision_type, reasoning, provider_amount, client_refund_amount, decided_by_system, created_at')
        .eq('dispute_id', dispute.id as string)
        .order('created_at', { ascending: true });
      decisions = decs ?? [];

      // Dispute communication events (Phase 3.3) feed the SAME unified timeline.
      // Internal admin notes and soft-hidden rows are excluded — this is the
      // participant-facing record. kind classifies each entry for labelling.
      const { data: msgs } = await this.supabase.client
        .from('dispute_messages')
        .select('sender_type, kind, created_at')
        .eq('dispute_id', dispute.id as string)
        .eq('internal', false)
        .is('hidden_at', null)
        .order('created_at', { ascending: true });
      disputeMessages = (msgs ?? []) as unknown as Array<Record<string, unknown>>;
    }

    // Derive a chronological timeline from canonical timestamps.
    const timeline: Array<{ type: string; label: string; at: string }> = [];
    const add = (type: string, label: string, at: unknown): void => {
      if (at) timeline.push({ type, label, at: at as string });
    };
    add('post_created', 'Request posted', post.created_at);
    if (tx && tx.status !== 'pending' && tx.status !== 'failed') {
      add('payment_secured', 'Payment secured in escrow', tx.created_at);
    }
    if (completion) {
      add('completion_requested', 'Provider marked the job as done', completion.created_at);
      if (completion.status === 'approved') add('completion_approved', 'You approved the completion', completion.reviewed_at);
      if (completion.status === 'disputed') add('completion_disputed', 'Completion disputed', completion.reviewed_at);
    }
    if (dispute) {
      add('dispute_opened', 'Dispute opened — funds frozen', dispute.created_at);
      add('dispute_reviewing', 'Admin started reviewing', dispute.first_response_at);
      // Communication events — merged chronologically by the sort below.
      for (const m of disputeMessages) {
        const kind = m.kind as string;
        const sender = m.sender_type as string;
        if (kind === 'evidence_request') {
          add('dispute_evidence_requested', 'Admin requested additional evidence', m.created_at);
        } else if (kind === 'evidence_submitted') {
          add('dispute_evidence_uploaded', 'Evidence submitted', m.created_at);
        } else if (kind === 'text' && sender === 'admin') {
          add('dispute_admin_reply', 'Support replied', m.created_at);
        } else if (kind === 'text' && (sender === 'client' || sender === 'provider')) {
          add('dispute_participant_reply', `${sender === 'client' ? 'Client' : 'Provider'} replied`, m.created_at);
        }
      }
      add('dispute_escalated', 'Escalated to senior admin', dispute.escalated_at);
      for (const d of decisions) {
        add('dispute_decision', `Decision: ${this.decisionLabel(d.decision_type as string)}`, d.created_at);
      }
      add('dispute_resolved', 'Dispute resolved', dispute.resolved_at);
    }
    if (escrow && escrow.status === 'released') add('payout_released', 'Payout released to provider', escrow.released_at);
    timeline.sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime());

    // ── Canonical derived settlement state (Phase 3.4A) — read-only ─────────────
    // The single money-truth the UI consumes instead of inferring from four
    // statuses. activeDispute uses the SAME terminal set as archivePost so
    // settlement.can_archive stays in exact parity with the enforcement gate.
    const disputeTerminal = ['resolved', 'resolved_release', 'resolved_refund', 'resolved_partial', 'merged'];
    const activeDispute = dispute != null && !disputeTerminal.includes(dispute.status as string);
    const latestDecision = decisions.length > 0 ? decisions[decisions.length - 1] : null;
    const settlement = deriveSettlementState({
      txStatus: (tx?.status as string | null) ?? null,
      escrowStatus: (escrow?.status as string | null) ?? null,
      failureReason: (tx?.failure_reason as string | null) ?? null,
      activeDispute,
      latestDecisionType: (latestDecision?.decision_type as string | null) ?? null,
      amount: (tx?.amount as number | null) ?? null,
      fee: (tx?.fee as number | null) ?? null,
      totalPaid: (tx?.total_paid as number | null) ?? null,
      providerAmount:
        (latestDecision?.provider_amount as number | null) ?? (dispute?.provider_amount as number | null) ?? null,
      clientRefund:
        (latestDecision?.client_refund_amount as number | null) ?? (dispute?.buyer_refund as number | null) ?? null,
      paidAt: (tx?.created_at as string | null) ?? null,
      releasedAt: (escrow?.released_at as string | null) ?? null,
      disputedAt: (dispute?.created_at as string | null) ?? null,
      resolvedAt: (dispute?.resolved_at as string | null) ?? null,
    });

    return {
      post: {
        id: post.id,
        title: post.title,
        price: post.price,
        status: post.status,
        author_user_id: authorId,
        selected_provider_id: providerId || null,
      },
      viewer_role: isClient ? 'client' : 'provider',
      settlement,
      payment: tx
        ? {
            transaction_id: tx.id,
            status: tx.status,
            amount: tx.amount,
            fee: tx.fee,
            total_paid: tx.total_paid,
            mpesa_receipt: isClient ? tx.mpesa_receipt : null,
            created_at: tx.created_at,
          }
        : null,
      escrow: escrow ? { status: escrow.status, released_at: escrow.released_at } : null,
      completion: completion ?? null,
      dispute: dispute ? { ...dispute, decisions } : null,
      timeline,
    };
  }

  private decisionLabel(type: string): string {
    switch (type) {
      case 'FULL_RELEASE': return 'Full payment released to provider';
      case 'FULL_REFUND': return 'Full refund to client';
      case 'PARTIAL_SPLIT': return 'Payment split between both parties';
      case 'ESCALATE': return 'Escalated to senior admin';
      default: return type;
    }
  }

  // ── Archive (soft delete) ───────────────────────────────────────────────────
  //
  // Never hard-deletes (that SET-NULLs chats.post_id and collides with
  // idx_chats_unique_null, and is blocked by RESTRICT on transactions/escrow).
  // Sets posts.archived_at so the post leaves feeds but all history is kept.
  // Enforces the deletion policy matrix server-side.
  async archivePost(postId: string, userId: string): Promise<{ archived: true; status: string }> {
    if (!userId) throw new BadRequestException('user_id is required.');

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, author_user_id, selected_provider_id, status, archived_at')
      .eq('id', postId)
      .single();
    if (!post) throw new NotFoundException(`Post ${postId} not found.`);

    if (post.author_user_id !== userId) {
      throw new ForbiddenException('Only the author can remove this post.');
    }
    // Idempotent: already archived.
    if (post.archived_at) return { archived: true, status: post.status as string };

    // ── Policy: block on active dispute ─────────────────────────────────────
    const { data: disputeRows } = await this.supabase.client
      .from('disputes')
      .select('status')
      .eq('post_id', postId);
    const terminal = ['resolved', 'resolved_release', 'resolved_refund', 'resolved_partial', 'merged'];
    const activeDispute = (disputeRows ?? []).some((d) => !terminal.includes((d as { status: string }).status));

    // ── Enforcement gate (UNCHANGED): block while funds are held in escrow ──
    // Existence-based over ALL rows for the post, so multi-transaction edge cases
    // stay strictly blocked. Never loosened — a payout_pending tx or escrow always
    // blocks archival.
    const { data: heldTx } = await this.supabase.client
      .from('transactions')
      .select('id')
      .eq('post_id', postId)
      .in('status', ['paid', 'payout_pending'])
      .limit(1)
      .maybeSingle();
    const { data: heldEscrow } = await this.supabase.client
      .from('escrow')
      .select('id')
      .eq('post_id', postId)
      .in('status', ['locked', 'payout_pending'])
      .limit(1)
      .maybeSingle();
    const fundsHeld = !!(heldTx || heldEscrow);

    // ── Canonical settlement state for the block message (single source) ─────
    // Reads the latest transaction + its escrow. The enforcement DECISION stays
    // the existence gate above (never loosened); this only drives the message,
    // so display (lifecycle) and enforcement share ONE derivation (Phase C P4).
    const { data: latestTx } = await this.supabase.client
      .from('transactions')
      .select('id, status, failure_reason')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    let escrowRow: { status: string } | null = null;
    if (latestTx) {
      const { data: esc } = await this.supabase.client
        .from('escrow')
        .select('status')
        .eq('transaction_id', latestTx.id as string)
        .maybeSingle();
      escrowRow = (esc as { status: string } | null) ?? null;
    }

    const settlement = deriveSettlementState({
      txStatus: (latestTx?.status as string | null) ?? null,
      escrowStatus: escrowRow?.status ?? null,
      failureReason: (latestTx?.failure_reason as string | null) ?? null,
      activeDispute,
      latestDecisionType: null,
      amount: null, fee: null, totalPaid: null, providerAmount: null, clientRefund: null,
      paidAt: null, releasedAt: null, disputedAt: null, resolvedAt: null,
    });

    // ── Enforce (decision = existence gate, UNCHANGED; message = canonical) ──
    if (activeDispute) {
      throw new ConflictException('This job has an active dispute and cannot be removed until resolution.');
    }
    if (fundsHeld) {
      // Truthful, state-specific message from the ONE canonical function. Fallback
      // covers the rare multi-transaction case where the latest tx reads terminal
      // while an older row is still held.
      throw new ConflictException(
        settlement.can_archive
          ? 'Funds are currently held. Resolve or complete the job before removing it.'
          : settlement.explanation,
      );
    }

    // ── Archive ─────────────────────────────────────────────────────────────
    const providerId = post.selected_provider_id as string | null;
    const now = new Date().toISOString();
    const update: Record<string, unknown> = { archived_at: now, archived_by: userId };

    // Provider was selected but the job never reached escrow → cancel the workflow.
    const cancelWorkflow = post.status === 'assigned' && !!providerId;
    if (cancelWorkflow) update.status = 'cancelled';

    await this.supabase.client.from('posts').update(update).eq('id', postId);

    if (cancelWorkflow && providerId) {
      await this.notifications.send({
        userId: providerId,
        type: 'job_cancelled',
        title: 'Job Cancelled',
        body: 'A client removed a job you were selected for before payment was made.',
        data: { post_id: postId },
      });
    }

    this.logger.log(`[ARCHIVE] post=${postId} by=${userId} status=${update.status ?? post.status}`);
    return { archived: true, status: (update.status as string) ?? (post.status as string) };
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  private async getPendingCompletion(postId: string) {
    const { data } = await this.supabase.client
      .from('job_completions')
      .select('id')
      .eq('post_id', postId)
      .eq('status', 'pending_approval')
      .maybeSingle();

    if (!data) {
      throw new BadRequestException('No pending completion request found for this job.');
    }
    return data;
  }
}
