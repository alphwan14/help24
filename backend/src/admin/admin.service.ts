import {
  BadRequestException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { MpesaService } from '../mpesa/mpesa.service';
import { EventsService } from '../events/events.service';
import { EVENT_TYPES } from '../events/event.types';
import { ResolveDisputeDto } from './dto/resolve-dispute.dto';

@Injectable()
export class AdminService {
  private readonly logger = new Logger(AdminService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly mpesa: MpesaService,
    private readonly events: EventsService,
  ) {}

  // ── List disputes ──────────────────────────────────────────────────────────

  async listDisputes(status?: string) {
    let query = this.supabase.client
      .from('disputes')
      .select(`
        id, status, reason, admin_notes, resolved_by,
        provider_amount, buyer_refund, created_at, resolved_at,
        posts(id, title, price),
        transactions(id, amount, total_paid, mpesa_receipt),
        raised_by:raised_by_user_id(id, name, phone_number)
      `)
      .order('created_at', { ascending: false })
      .limit(200);

    if (status) {
      query = query.eq('status', status);
    }

    const { data, error } = await query;
    if (error) throw new BadRequestException(error.message);
    return data ?? [];
  }

  // ── Get dispute detail ─────────────────────────────────────────────────────

  async getDispute(disputeId: string) {
    const { data, error } = await this.supabase.client
      .from('disputes')
      .select(`
        id, status, reason, admin_notes, resolved_by,
        provider_amount, buyer_refund, created_at, resolved_at,
        posts(id, title, price, author_user_id, selected_provider_id, status),
        transactions(id, amount, fee, total_paid, status, mpesa_receipt, created_at),
        job_completions(id, status, provider_note, created_at, reviewed_at),
        raised_by:raised_by_user_id(id, name, phone_number)
      `)
      .eq('id', disputeId)
      .single();

    if (error || !data) throw new NotFoundException(`Dispute ${disputeId} not found.`);

    const post = data.posts as unknown as Record<string, unknown> | null;
    let buyer = null;
    let provider = null;

    if (post) {
      const [buyerRes, providerRes] = await Promise.all([
        this.supabase.client
          .from('users')
          .select('id, name, phone_number')
          .eq('id', post.author_user_id as string)
          .single(),
        this.supabase.client
          .from('users')
          .select('id, name, phone_number')
          .eq('id', post.selected_provider_id as string)
          .single(),
      ]);
      buyer = buyerRes.data;
      provider = providerRes.data;
    }

    return { ...data, buyer, provider };
  }

  // ── Resolve dispute ────────────────────────────────────────────────────────

  async resolveDispute(dto: ResolveDisputeDto): Promise<{ message: string }> {
    this.logger.log(
      `[ADMIN] resolveDispute id=${dto.dispute_id} action=${dto.action} by=${dto.resolved_by}`,
    );

    if (dto.action === 'partial_split') {
      if (dto.provider_amount == null || dto.buyer_refund == null) {
        throw new BadRequestException(
          'partial_split requires both provider_amount and buyer_refund.',
        );
      }
    }

    const { data: disputeRecord, error: disputeErr } = await this.supabase.client
      .from('disputes')
      .select('id, status, post_id, transaction_id')
      .eq('id', dto.dispute_id)
      .single();

    if (disputeErr || !disputeRecord) {
      throw new NotFoundException(`Dispute ${dto.dispute_id} not found.`);
    }

    if (
      disputeRecord.status === 'resolved_release' ||
      disputeRecord.status === 'resolved_refund' ||
      disputeRecord.status === 'resolved_partial'
    ) {
      throw new BadRequestException('This dispute has already been resolved.');
    }

    const postId       = disputeRecord.post_id as string;
    const transactionId = disputeRecord.transaction_id as string;

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('title, author_user_id, selected_provider_id')
      .eq('id', postId)
      .single();

    if (!post) throw new NotFoundException(`Post ${postId} not found.`);

    const providerId = post.selected_provider_id as string;
    const buyerId    = post.author_user_id as string;
    const postTitle  = post.title as string;

    const statusMap: Record<string, string> = {
      release_full:  'resolved_release',
      refund_full:   'resolved_refund',
      partial_split: 'resolved_partial',
    };
    const newStatus = statusMap[dto.action];

    await this.supabase.client
      .from('disputes')
      .update({
        status:          newStatus,
        admin_notes:     dto.admin_notes ?? null,
        resolved_by:     dto.resolved_by,
        provider_amount: dto.provider_amount ?? null,
        buyer_refund:    dto.buyer_refund ?? null,
        resolved_at:     new Date().toISOString(),
      })
      .eq('id', dto.dispute_id);

    await this.supabase.client
      .from('posts')
      .update({ status: 'completed' })
      .eq('id', postId);

    // Execute the resolution action.
    if (dto.action === 'release_full') {
      await this.executeRelease(transactionId, postId, postTitle, providerId, buyerId);
    } else if (dto.action === 'refund_full') {
      await this.executeRefund(transactionId, postId, postTitle, providerId, buyerId);
    } else {
      await this.executePartialSplit(
        transactionId, postId, postTitle, providerId, buyerId,
        dto.provider_amount!, dto.buyer_refund!,
      );
    }

    // Emit audit event for the resolution.
    const eventTypeMap: Record<string, typeof EVENT_TYPES[keyof typeof EVENT_TYPES]> = {
      release_full:  EVENT_TYPES.DISPUTE_RESOLVED_RELEASE,
      refund_full:   EVENT_TYPES.DISPUTE_RESOLVED_REFUND,
      partial_split: EVENT_TYPES.DISPUTE_RESOLVED_PARTIAL,
    };

    void this.events.emit({
      type:          eventTypeMap[dto.action],
      actorUserId:   dto.resolved_by,
      entityType:    'dispute',
      entityId:      dto.dispute_id,
      payload: {
        post_id:         postId,
        post_title:      postTitle,
        provider_id:     providerId,
        buyer_id:        buyerId,
        transaction_id:  transactionId,
        provider_amount: dto.provider_amount ?? null,
        buyer_refund:    dto.buyer_refund ?? null,
      },
    });

    this.logger.log(`[ADMIN] Dispute ${dto.dispute_id} resolved with action=${dto.action}`);
    return { message: `Dispute resolved: ${dto.action}` };
  }

  // ── Private resolution executors ───────────────────────────────────────────

  private async executeRelease(
    transactionId: string,
    postId: string,
    postTitle: string,
    providerId: string,
    buyerId: string,
  ) {
    try {
      await this.mpesa.releasePayout({ post_id: postId });
    } catch (err) {
      this.logger.error(
        `[ADMIN] B2C payout failed for dispute release on post ${postId}: ${err instanceof Error ? err.message : String(err)}`,
      );
      await this.setEscrowReleased(transactionId);
    }

    await this.notifications.sendMany([
      {
        userId: providerId,
        type: 'dispute_resolved_release',
        title: 'Dispute Resolved — Payout Approved',
        body: `Admin reviewed "${postTitle}" and released the full payment to you.`,
        data: { post_id: postId },
      },
      {
        userId: buyerId,
        type: 'dispute_resolved_release',
        title: 'Dispute Resolved',
        body: `Admin reviewed "${postTitle}" and released payment to the provider.`,
        data: { post_id: postId },
      },
    ]);
  }

  private async executeRefund(
    transactionId: string,
    postId: string,
    postTitle: string,
    providerId: string,
    buyerId: string,
  ) {
    await this.supabase.client
      .from('transactions')
      .update({ status: 'refunded' })
      .eq('id', transactionId);

    await this.supabase.client
      .from('escrow')
      .update({ status: 'refunded', released_at: new Date().toISOString() })
      .eq('transaction_id', transactionId);

    await this.notifications.sendMany([
      {
        userId: buyerId,
        type: 'dispute_resolved_refund',
        title: 'Refund Approved',
        body: `Admin reviewed "${postTitle}" and approved a full refund. You will receive your M-Pesa refund shortly.`,
        data: { post_id: postId },
      },
      {
        userId: providerId,
        type: 'dispute_resolved_refund',
        title: 'Dispute Resolved',
        body: `Admin reviewed "${postTitle}" and issued a full refund to the client.`,
        data: { post_id: postId },
      },
    ]);
  }

  private async executePartialSplit(
    transactionId: string,
    postId: string,
    postTitle: string,
    providerId: string,
    buyerId: string,
    providerAmount: number,
    buyerRefund: number,
  ) {
    await this.supabase.client
      .from('transactions')
      .update({ status: 'refunded' })
      .eq('id', transactionId);

    await this.supabase.client
      .from('escrow')
      .update({ status: 'refunded', released_at: new Date().toISOString() })
      .eq('transaction_id', transactionId);

    await this.notifications.sendMany([
      {
        userId: providerId,
        type: 'dispute_resolved_partial',
        title: 'Dispute Resolved — Partial Payment',
        body: `Admin split the payment for "${postTitle}". You will receive KES ${providerAmount.toLocaleString()} via M-Pesa.`,
        data: { post_id: postId, amount: String(providerAmount) },
      },
      {
        userId: buyerId,
        type: 'dispute_resolved_partial',
        title: 'Dispute Resolved — Partial Refund',
        body: `Admin split the payment for "${postTitle}". You will receive a refund of KES ${buyerRefund.toLocaleString()} via M-Pesa.`,
        data: { post_id: postId, amount: String(buyerRefund) },
      },
    ]);
  }

  private async setEscrowReleased(transactionId: string) {
    await this.supabase.client
      .from('escrow')
      .update({ status: 'released', released_at: new Date().toISOString() })
      .eq('transaction_id', transactionId);
  }
}
