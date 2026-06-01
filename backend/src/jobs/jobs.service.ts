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
import { ApproveDto, DisputeDto } from './dto/client-decision.dto';

@Injectable()
export class JobsService {
  private readonly logger = new Logger(JobsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly events: EventsService,
  ) {}

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
    await this.notifications.send({
      userId: post.author_user_id as string,
      type: 'completion_requested',
      title: 'Job Marked as Done',
      body: `Your provider has marked "${post.title as string}" as complete. Review and approve or dispute.`,
      data: { post_id: dto.post_id, completion_id: completionId },
    });

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

    // Notify both parties inline for speed (event processor will also send — but
    // notifications.service deduplication is not implemented, so we only notify inline).
    await this.notifications.sendMany([
      {
        userId: post.selected_provider_id as string,
        type: 'payout_released',
        title: 'Payout Initiated!',
        body: `The client approved "${post.title as string}". Your M-Pesa payout is being processed.`,
        data: { post_id: dto.post_id },
      },
      {
        userId: dto.client_user_id,
        type: 'job_approved',
        title: 'Job Approved',
        body: `You approved "${post.title as string}". The provider's payout has been initiated.`,
        data: { post_id: dto.post_id },
      },
    ]);

    this.logger.log(`[JOBS] Post ${dto.post_id} approved — payout queued via event.`);
    return { message: 'Job approved. Payout is being processed.' };
  }

  // ── Client: open dispute → freeze escrow ──────────────────────────────────

  async dispute(dto: DisputeDto): Promise<{ dispute_id: string }> {
    this.logger.log(`[JOBS] dispute post=${dto.post_id} client=${dto.client_user_id}`);

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id, selected_provider_id')
      .eq('id', dto.post_id)
      .single();

    if (!post) throw new NotFoundException(`Post ${dto.post_id} not found.`);

    if (post.author_user_id !== dto.client_user_id) {
      throw new ForbiddenException('Only the post author can dispute a completion.');
    }

    const completion = await this.getPendingCompletion(dto.post_id);

    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('id, status')
      .eq('post_id', dto.post_id)
      .in('status', ['paid', 'payout_pending'])
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!tx) throw new BadRequestException('No active transaction found to dispute.');

    await this.supabase.client
      .from('job_completions')
      .update({ status: 'disputed', reviewed_at: new Date().toISOString() })
      .eq('id', completion.id);

    await this.supabase.client
      .from('transactions')
      .update({ status: 'disputed' })
      .eq('id', tx.id);

    await this.supabase.client
      .from('escrow')
      .update({ status: 'disputed' })
      .eq('transaction_id', tx.id);

    await this.supabase.client
      .from('posts')
      .update({ status: 'disputed' })
      .eq('id', dto.post_id);

    const { data: disputeRecord, error: disputeErr } = await this.supabase.client
      .from('disputes')
      .insert({
        post_id:              dto.post_id,
        transaction_id:       tx.id,
        job_completion_id:    completion.id,
        raised_by_user_id:    dto.client_user_id,
        reason:               dto.reason,
        status:               'open',
      })
      .select('id')
      .single();

    if (disputeErr || !disputeRecord) {
      this.logger.error(`[JOBS] Failed to create dispute record: ${disputeErr?.message ?? 'null'}`);
      throw new BadRequestException('Failed to open dispute.');
    }

    const disputeId = disputeRecord.id as string;

    void this.events.emit({
      type: EVENT_TYPES.JOB_DISPUTED,
      actorUserId: dto.client_user_id,
      entityType: 'dispute',
      entityId: disputeId,
      payload: {
        post_id:        dto.post_id,
        post_title:     post.title as string,
        provider_id:    post.selected_provider_id as string,
        client_user_id: dto.client_user_id,
        dispute_id:     disputeId,
        transaction_id: tx.id,
      },
    });

    // Notify inline as fast path.
    await this.notifications.sendMany([
      {
        userId: post.selected_provider_id as string,
        type: 'dispute_opened',
        title: 'Dispute Opened',
        body: `The client has raised a dispute on "${post.title as string}". Funds are frozen pending admin review.`,
        data: { post_id: dto.post_id, dispute_id: disputeId },
      },
      {
        userId: dto.client_user_id,
        type: 'dispute_opened',
        title: 'Dispute Submitted',
        body: `Your dispute on "${post.title as string}" has been submitted. Admin will review within 24-48 hours.`,
        data: { post_id: dto.post_id, dispute_id: disputeId },
      },
    ]);

    this.logger.log(`[JOBS] Dispute ${disputeId} opened for post ${dto.post_id}`);
    return { dispute_id: disputeId };
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
