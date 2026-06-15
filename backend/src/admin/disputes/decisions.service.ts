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
import { MpesaService } from '../../mpesa/mpesa.service';
import { EventsService } from '../../events/events.service';
import { EVENT_TYPES, EventType } from '../../events/event.types';
import { AdminContext, roleAtLeast } from '../auth/admin-role';
import { DecisionDto, DecisionType } from './dto/decision.dto';
import { DisputesService } from './disputes.service';

const TERMINAL = ['resolved', 'escalated', 'merged', 'resolved_release', 'resolved_refund', 'resolved_partial'];

/**
 * The decision execution engine — the financial "ruling" layer.
 *
 * Responsibilities, in strict order:
 *   1. Authorize (role + case lock).
 *   2. Validate the ruling against current escrow state (no double-payout, no
 *      refund after release).
 *   3. Write the IMMUTABLE dispute_decisions row (the audit ledger).
 *   4. Execute the money movement (FULL_RELEASE = automated B2C; FULL_REFUND /
 *      PARTIAL_SPLIT = recorded, cash settled manually by finance).
 *   5. Transition dispute + job, emit events, notify, append to the court thread.
 *
 * Steps 3–5 are append-only/idempotent so a mid-flight failure can be retried
 * without corrupting the ledger.
 */
@Injectable()
export class DecisionsService {
  private readonly logger = new Logger(DecisionsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly mpesa: MpesaService,
    private readonly events: EventsService,
    private readonly disputes: DisputesService,
  ) {}

  async decide(
    disputeId: string,
    dto: DecisionDto,
    admin: AdminContext,
  ): Promise<{ decision_id: string; decision_type: DecisionType; message: string }> {
    const dispute = await this.disputes.requireDispute(disputeId);

    // ── 1. Authorize ──────────────────────────────────────────────────────────
    if (TERMINAL.includes(dispute.status as string)) {
      throw new ConflictException('This dispute is already closed; decisions are immutable.');
    }

    const assignee = dispute.assigned_admin_id as string | null;
    const isOwner = assignee === admin.id;
    const isSuper = admin.role === 'super_admin';
    if (assignee && !isOwner && !isSuper) {
      throw new ConflictException('Case is assigned to another admin. Only they or a super_admin may rule.');
    }
    if (!assignee && !isSuper) {
      throw new ConflictException('Claim (assign) the case before issuing a decision.');
    }

    // Financial rulings require senior_admin+. ESCALATE is open to any admin.
    if (dto.decision_type !== 'ESCALATE' && !roleAtLeast(admin.role, 'senior_admin')) {
      throw new ForbiddenException('Financial decisions require senior_admin or higher.');
    }

    // ── 2. Validate against escrow state ────────────────────────────────────────
    const postId = dispute.post_id as string;
    const txId = dispute.transaction_id as string;

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('title, author_user_id, selected_provider_id')
      .eq('id', postId)
      .single();
    if (!post) throw new NotFoundException(`Post ${postId} not found.`);

    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('id, status, amount, total_paid')
      .eq('id', txId)
      .single();
    if (!tx) throw new NotFoundException('Transaction not found.');

    const providerId = post.selected_provider_id as string;
    const buyerId = post.author_user_id as string;
    const postTitle = post.title as string;
    const escrowAmount = (tx.amount as number) ?? 0;
    const txStatus = tx.status as string;

    // Edge case: dispute decided after funds already moved → no reversal path.
    if ((txStatus === 'released' || txStatus === 'refunded') && dto.decision_type !== 'ESCALATE') {
      throw new ConflictException(
        `Funds are already '${txStatus}'. This case must be ESCALATEd for manual reversal — it cannot be auto-settled.`,
      );
    }

    this.validateAmounts(dto, escrowAmount);

    // ── 3. Write the immutable decision row FIRST (audit before action) ─────────
    const providerAmount = this.providerAmountFor(dto, escrowAmount);
    const clientRefund = this.clientRefundFor(dto, tx.total_paid as number);

    const { data: decision, error: decErr } = await this.supabase.client
      .from('dispute_decisions')
      .insert({
        dispute_id: disputeId,
        admin_id: admin.id,
        decided_by_system: false,
        decision_type: dto.decision_type,
        provider_amount: providerAmount,
        client_refund_amount: clientRefund,
        reasoning: dto.reasoning,
      })
      .select('id')
      .single();

    if (decErr || !decision) {
      this.logger.error(`[DECISION] ledger write failed: ${decErr?.message ?? 'null'}`);
      throw new BadRequestException('Failed to record decision.');
    }
    const decisionId = decision.id as string;
    this.logger.log(`[DECISION] ${dto.decision_type} dispute=${disputeId} by=${admin.email} ledger=${decisionId}`);

    // ── 4 + 5. Execute, transition, notify ──────────────────────────────────────
    if (dto.decision_type === 'ESCALATE') {
      await this.applyEscalation(disputeId, admin, dto.reasoning, postTitle, providerId, buyerId, postId);
    } else {
      await this.applyFinancial(
        dto.decision_type, disputeId, txId, postId, postTitle,
        providerId, buyerId, providerAmount, clientRefund, admin,
      );
    }

    return {
      decision_id: decisionId,
      decision_type: dto.decision_type,
      message: this.summaryFor(dto.decision_type, providerAmount, clientRefund),
    };
  }

  // ── System-initiated escalation (used by SlaService) ────────────────────────

  /** Auto-escalate a stale case. Writes a SYSTEM decision row (no admin). */
  async systemEscalate(disputeId: string, reasoning: string): Promise<void> {
    const dispute = await this.disputes.requireDispute(disputeId);
    if (TERMINAL.includes(dispute.status as string)) return;

    const { data } = await this.supabase.client
      .from('dispute_decisions')
      .insert({
        dispute_id: disputeId,
        admin_id: null,
        decided_by_system: true,
        decision_type: 'ESCALATE',
        reasoning,
      })
      .select('id')
      .single();

    await this.supabase.client
      .from('disputes')
      .update({ status: 'escalated', escalated_at: new Date().toISOString() })
      .eq('id', disputeId);

    await this.disputes.systemMessage(disputeId, `Auto-escalated by SLA monitor: ${reasoning}`);
    await this.notifySuperAdmins(`Dispute ${disputeId} auto-escalated`, reasoning);
    this.logger.warn(`[DECISION] system-escalated dispute=${disputeId} ledger=${data?.id as string}`);
  }

  // ── Execution branches ───────────────────────────────────────────────────────

  private async applyFinancial(
    type: Exclude<DecisionType, 'ESCALATE'>,
    disputeId: string,
    txId: string,
    postId: string,
    postTitle: string,
    providerId: string,
    buyerId: string,
    providerAmount: number,
    clientRefund: number,
    admin: AdminContext,
  ): Promise<void> {
    if (type === 'FULL_RELEASE') {
      // Automated B2C to provider. Falls back to a DB-only release on B2C error
      // so escrow never gets stuck (mirrors the existing approve() path).
      try {
        await this.mpesa.releasePayout({ post_id: postId });
      } catch (err) {
        this.logger.error(
          `[DECISION] B2C failed for release on post ${postId}: ${err instanceof Error ? err.message : String(err)}`,
        );
        await this.supabase.client
          .from('escrow')
          .update({ status: 'released', released_at: new Date().toISOString() })
          .eq('transaction_id', txId);
      }
    } else {
      // FULL_REFUND / PARTIAL_SPLIT — recorded immutably; cash settled manually.
      await this.supabase.client.from('transactions').update({ status: 'refunded' }).eq('id', txId);
      await this.supabase.client
        .from('escrow')
        .update({ status: 'refunded', released_at: new Date().toISOString() })
        .eq('transaction_id', txId);
    }

    // Close the dispute (status='resolved') and the job.
    await this.supabase.client
      .from('disputes')
      .update({
        status: 'resolved',
        resolved_by: admin.email,
        resolved_at: new Date().toISOString(),
        provider_amount: providerAmount,
        buyer_refund: clientRefund,
      })
      .eq('id', disputeId);

    await this.supabase.client.from('posts').update({ status: 'completed' }).eq('id', postId);

    // Audit event (drives the existing notification handlers too).
    const eventType: EventType =
      type === 'FULL_RELEASE'
        ? EVENT_TYPES.DISPUTE_RESOLVED_RELEASE
        : type === 'FULL_REFUND'
          ? EVENT_TYPES.DISPUTE_RESOLVED_REFUND
          : EVENT_TYPES.DISPUTE_RESOLVED_PARTIAL;

    void this.events.emit({
      type: eventType,
      actorUserId: admin.id,
      entityType: 'dispute',
      entityId: disputeId,
      payload: {
        post_id: postId, post_title: postTitle, provider_id: providerId, buyer_id: buyerId,
        transaction_id: txId, provider_amount: providerAmount, buyer_refund: clientRefund,
        decided_by: admin.email,
      },
    });

    await this.notifyParties(type, postTitle, postId, providerId, buyerId, providerAmount, clientRefund);
    await this.disputes.systemMessage(
      disputeId,
      `Decision: ${type} by ${admin.name || admin.email}. ${this.summaryFor(type, providerAmount, clientRefund)}`,
    );
  }

  private async applyEscalation(
    disputeId: string,
    admin: AdminContext,
    reasoning: string,
    postTitle: string,
    _providerId: string,
    _buyerId: string,
    _postId: string,
  ): Promise<void> {
    await this.supabase.client
      .from('disputes')
      .update({ status: 'escalated', escalated_at: new Date().toISOString() })
      .eq('id', disputeId);

    await this.disputes.systemMessage(disputeId, `Escalated by ${admin.name || admin.email}: ${reasoning}`);
    await this.notifySuperAdmins(`Dispute escalated: "${postTitle}"`, reasoning);
  }

  // ── Validation + amount math ─────────────────────────────────────────────────

  private validateAmounts(dto: DecisionDto, escrowAmount: number): void {
    if (dto.decision_type === 'PARTIAL_SPLIT') {
      if (dto.provider_amount == null || dto.client_refund_amount == null) {
        throw new BadRequestException('PARTIAL_SPLIT requires provider_amount and client_refund_amount.');
      }
      if (dto.provider_amount + dto.client_refund_amount > escrowAmount) {
        throw new BadRequestException(
          `Split exceeds escrow: provider + refund (${dto.provider_amount + dto.client_refund_amount}) > held (${escrowAmount}).`,
        );
      }
      if (dto.provider_amount === 0 && dto.client_refund_amount === 0) {
        throw new BadRequestException('A PARTIAL_SPLIT must allocate a non-zero amount.');
      }
    }
  }

  private providerAmountFor(dto: DecisionDto, escrowAmount: number): number | null {
    switch (dto.decision_type) {
      case 'FULL_RELEASE': return escrowAmount;
      case 'FULL_REFUND': return 0;
      case 'PARTIAL_SPLIT': return dto.provider_amount ?? 0;
      default: return null; // ESCALATE
    }
  }

  private clientRefundFor(dto: DecisionDto, totalPaid: number): number | null {
    switch (dto.decision_type) {
      case 'FULL_RELEASE': return 0;
      case 'FULL_REFUND': return totalPaid;
      case 'PARTIAL_SPLIT': return dto.client_refund_amount ?? 0;
      default: return null; // ESCALATE
    }
  }

  private summaryFor(type: DecisionType, providerAmount: number | null, clientRefund: number | null): string {
    switch (type) {
      case 'FULL_RELEASE': return `Released KES ${(providerAmount ?? 0).toLocaleString()} to provider.`;
      case 'FULL_REFUND': return `Refunded KES ${(clientRefund ?? 0).toLocaleString()} to client (manual M-Pesa).`;
      case 'PARTIAL_SPLIT':
        return `Provider KES ${(providerAmount ?? 0).toLocaleString()}, client refund KES ${(clientRefund ?? 0).toLocaleString()}.`;
      case 'ESCALATE': return 'Escalated to super_admin.';
    }
  }

  // ── Notifications ────────────────────────────────────────────────────────────

  private async notifyParties(
    type: Exclude<DecisionType, 'ESCALATE'>,
    postTitle: string, postId: string,
    providerId: string, buyerId: string,
    providerAmount: number, clientRefund: number,
  ): Promise<void> {
    if (type === 'FULL_RELEASE') {
      await this.notifications.sendMany([
        { userId: providerId, type: 'dispute_resolved_release', title: 'Dispute Resolved — Payout Approved',
          body: `Admin released the full payment for "${postTitle}" to you.`, data: { post_id: postId } },
        { userId: buyerId, type: 'dispute_resolved_release', title: 'Dispute Resolved',
          body: `Admin released payment for "${postTitle}" to the provider.`, data: { post_id: postId } },
      ]);
    } else if (type === 'FULL_REFUND') {
      await this.notifications.sendMany([
        { userId: buyerId, type: 'dispute_resolved_refund', title: 'Refund Approved',
          body: `Admin approved a full refund for "${postTitle}". Your M-Pesa refund will arrive shortly.`, data: { post_id: postId } },
        { userId: providerId, type: 'dispute_resolved_refund', title: 'Dispute Resolved',
          body: `Admin issued a full refund to the client for "${postTitle}".`, data: { post_id: postId } },
      ]);
    } else {
      await this.notifications.sendMany([
        { userId: providerId, type: 'dispute_resolved_partial', title: 'Dispute Resolved — Partial Payment',
          body: `Payment for "${postTitle}" was split. You will receive KES ${providerAmount.toLocaleString()}.`,
          data: { post_id: postId, amount: String(providerAmount) } },
        { userId: buyerId, type: 'dispute_resolved_partial', title: 'Dispute Resolved — Partial Refund',
          body: `Payment for "${postTitle}" was split. You will be refunded KES ${clientRefund.toLocaleString()}.`,
          data: { post_id: postId, amount: String(clientRefund) } },
      ]);
    }
  }

  private async notifySuperAdmins(title: string, body: string): Promise<void> {
    const { data: supers } = await this.supabase.client
      .from('admin_users')
      .select('id')
      .eq('role', 'super_admin')
      .eq('active', true);
    // Admins are not app users with FCM tokens; surface escalations in the court
    // thread + logs. (Hook an admin-channel notifier here if desired.)
    this.logger.warn(`[DECISION][ESCALATION] ${title} — ${body} (super_admins=${supers?.length ?? 0})`);
  }
}
