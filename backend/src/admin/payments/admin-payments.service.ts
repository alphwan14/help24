import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { SupabaseService } from '../../supabase/supabase.service';
import { NotificationsService } from '../../notifications/notifications.service';
import { MpesaService } from '../../mpesa/mpesa.service';
import { JobsService } from '../../jobs/jobs.service';
import { deriveSettlementState } from '../../jobs/settlement-state';
import { advancePaidOut } from '../../mpesa/advance';
import { DisputesService } from '../disputes/disputes.service';
import { AdminContext } from '../auth/admin-role';
import {
  PaymentActionId,
  PaymentFacts,
  activeDispute,
  availableActions,
  buildTimeline,
} from './payment-view';

type Row = Record<string, any>;

/** What an admin action records before it runs (admin_finance_actions, migrations 117 + 144). */
type AuditType = 'payout_retried' | 'payout_status_checked' | 'completion_approved' | 'dispute_opened' | 'hire_cancelled';

/**
 * One payment, for the dashboard's transaction page, and the actions an admin
 * can take on it. Every action:
 *   1. re-reads the payment and checks it is still offered (payment-view.ts)
 *      and that this admin's role may take it;
 *   2. writes its audit row (who, role, why, the state before) and refuses to
 *      go on if that cannot be written: no unrecorded money action;
 *   3. acts through the path the rest of the platform already uses (the
 *      payout, the approval, the dispute), never a parallel one.
 */
@Injectable()
export class AdminPaymentsService {
  private readonly logger = new Logger(AdminPaymentsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly mpesa: MpesaService,
    private readonly jobs: JobsService,
    private readonly disputes: DisputesService,
  ) {}

  private get db() {
    return this.supabase.client;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // The page
  // ═══════════════════════════════════════════════════════════════════════════

  async detail(txId: string, admin: AdminContext) {
    const facts = await this.load(txId);
    const tx = facts.raw.tx;
    const dispute = activeDispute(facts.facts);
    const latestDecision = facts.facts.decisions.at(-1) ?? null;
    const settlement = deriveSettlementState({
      txStatus: tx.status as string,
      escrowStatus: facts.facts.escrow?.status ?? null,
      failureReason: (tx.failure_reason as string | null) ?? null,
      activeDispute: dispute != null,
      latestDecisionType: latestDecision?.decision_type ?? null,
      amount: (tx.amount as number | null) ?? null,
      fee: (tx.fee as number | null) ?? null,
      totalPaid: (tx.total_paid as number | null) ?? null,
      providerAmount: (facts.raw.latestDisputeRow?.provider_amount as number | null) ?? null,
      clientRefund: (facts.raw.latestDisputeRow?.buyer_refund as number | null) ?? null,
      advancePaid: advancePaidOut(facts.raw.advance as never),
      paidAt: (tx.created_at as string | null) ?? null,
      releasedAt: facts.facts.escrow?.released_at ?? null,
      disputedAt: dispute?.created_at ?? null,
      resolvedAt: facts.raw.latestDisputeRow?.resolved_at ?? null,
    });

    return {
      transaction: {
        id: tx.id,
        status: tx.status,
        amount: tx.amount,
        fee: tx.fee,
        total_paid: tx.total_paid,
        phone: tx.phone ?? null,
        mpesa_receipt: tx.mpesa_receipt ?? null,
        receipt_number: facts.raw.receiptNumber,
        failure_reason: tx.failure_reason ?? null,
        created_at: tx.created_at,
      },
      settlement,
      post: facts.raw.post,
      client: facts.raw.client,
      provider: facts.raw.provider,
      escrow: facts.facts.escrow,
      completion: facts.facts.completion,
      materials_advance: facts.facts.advance,
      disputes: facts.facts.disputes,
      attempts: facts.facts.attempts,
      timeline: buildTimeline(facts.facts),
      actions: availableActions(facts.facts, admin.role),
      admin_actions: facts.facts.adminActions,
    };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Actions
  // ═══════════════════════════════════════════════════════════════════════════

  /** Send the provider's payout again: a failed one, or one that never went out. */
  async retryPayout(txId: string, admin: AdminContext, reason: string) {
    const { facts, raw } = await this.requireAction(txId, admin, 'retry_payout');
    await this.audit('payout_retried', facts, admin, reason);
    const result = await this.mpesa.releasePayout({ post_id: raw.tx.post_id as string });
    this.logger.warn(`[ADMIN_PAYMENTS] payout retried tx=${txId} by=${admin.email}`);
    return { ok: true, message: (result as { message?: string })?.message ?? 'Payout sent to M-Pesa.' };
  }

  /** Ask M-Pesa what happened to a payout with no answer. Settles only on M-Pesa's word. */
  async checkMpesa(txId: string, admin: AdminContext) {
    const { facts, raw } = await this.requireAction(txId, admin, 'check_mpesa');
    await this.audit('payout_status_checked', facts, admin, 'Asked M-Pesa for the status of this payout.');
    const result = await this.mpesa.reconcilePayout(raw.tx.post_id as string, admin.email);
    return { ok: true, message: result.message };
  }

  /** Approve finished work the client left waiting; the payout follows as for any approval. */
  async approveCompletion(txId: string, admin: AdminContext, reason: string) {
    const { facts, raw } = await this.requireAction(txId, admin, 'approve_completion');
    const post = raw.post;
    const completion = raw.completion;
    // The completion names who did the work: if the listing no longer agrees,
    // paying anyone is wrong (the same guard as the automatic approval).
    if (!post || !completion || post.selected_provider_id !== completion.provider_user_id || post.author_user_id !== completion.client_user_id) {
      throw new ConflictException('This job no longer matches its completion request. Check it before approving.');
    }
    await this.audit('completion_approved', facts, admin, reason);
    const won = await this.jobs.approveCompletion({
      completionId: completion.id as string,
      postId: post.id as string,
      postTitle: (post.title as string) ?? 'your job',
      providerId: completion.provider_user_id as string,
      clientUserId: completion.client_user_id as string,
      by: 'admin',
    });
    if (!won) throw new ConflictException('The completion was answered a moment ago. Reload to see what happened.');

    const title = (post.title as string) ?? 'your job';
    await this.notifySafely([
      {
        userId: completion.provider_user_id as string,
        type: 'payout_released',
        title: 'Job approved',
        body: `Help24 approved "${title}". Your M-Pesa payout is being processed.`,
        data: { post_id: post.id as string },
      },
      {
        userId: completion.client_user_id as string,
        type: 'job_approved',
        title: 'Job approved by Help24',
        body: `Help24 approved "${title}" and the provider is being paid. Contact support if something is wrong.`,
        data: { post_id: post.id as string },
      },
    ]);
    return { ok: true, message: 'Approved. The payout to the provider has started.' };
  }

  /** Open a dispute for the client or the provider; it is decided in Disputes. */
  async openDispute(txId: string, admin: AdminContext, raisedBy: 'client' | 'provider', reason: string) {
    const { facts, raw } = await this.requireAction(txId, admin, 'open_dispute');
    const post = raw.post!;
    const userId = (raisedBy === 'client' ? post.author_user_id : post.selected_provider_id) as string | null;
    if (!userId) throw new BadRequestException(`This job has no ${raisedBy}.`);
    await this.audit('dispute_opened', facts, admin, reason);
    const created = await this.disputes.createDispute(
      {
        post_id: post.id as string,
        raised_by_user_id: userId,
        raised_by_role: raisedBy,
        reason: `Opened by Help24 for the ${raisedBy}: ${reason.trim()}`.slice(0, 1000),
      },
      { openedByHelp24: true },
    );
    if (!created.deduped) {
      const { error } = await this.db.from('disputes').update({ opened_by_admin_id: admin.id }).eq('id', created.dispute_id);
      if (error) this.logger.warn(`[ADMIN_PAYMENTS] dispute ${created.dispute_id} opened; marking who opened it failed: ${error.message}`);
    }
    return {
      ok: true,
      dispute_id: created.dispute_id,
      message: created.deduped ? 'A dispute was already open for this job.' : 'Dispute opened. The money is frozen until it is decided.',
    };
  }

  /** Undo a hire that was never paid for: the request opens again for the client. */
  async cancelHire(txId: string, admin: AdminContext, reason: string) {
    const { facts, raw } = await this.requireAction(txId, admin, 'cancel_hire');
    const post = raw.post!;
    const providerId = post.selected_provider_id as string;
    await this.audit('hire_cancelled', facts, admin, reason);
    const { data: moved, error } = await this.db.from('posts')
      .update({ status: 'open', selected_provider_id: null })
      .eq('id', post.id).eq('status', 'assigned').eq('selected_provider_id', providerId)
      .select('id');
    if (error) throw new ServiceUnavailableException('Could not cancel the hire right now.');
    if (!moved?.length) throw new ConflictException('The job changed a moment ago. Reload to see what happened.');

    const title = (post.title as string) ?? 'the job';
    await this.notifySafely([
      {
        userId: providerId,
        type: 'job_cancelled',
        title: 'Job cancelled',
        body: `Help24 cancelled your booking for "${title}". It was never paid for, so nothing is owed.`,
        data: { post_id: post.id as string },
      },
      {
        userId: post.author_user_id as string,
        type: 'job_cancelled',
        title: 'Your request is open again',
        body: `Help24 removed the provider from "${title}" because it was never paid for. You can choose someone again.`,
        data: { post_id: post.id as string },
      },
    ]);
    return { ok: true, message: 'Hire cancelled. The request is open again.' };
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Internals
  // ═══════════════════════════════════════════════════════════════════════════

  /** Re-read the payment and check the action is offered to this admin now. */
  private async requireAction(txId: string, admin: AdminContext, id: PaymentActionId) {
    const loaded = await this.load(txId);
    const action = availableActions(loaded.facts, admin.role).find((a) => a.id === id);
    if (!action) throw new ConflictException('That action does not fit this payment as it stands now. Reload the page.');
    if (!action.allowed) throw new ForbiddenException(action.blocked_reason ?? 'Your role cannot take this action.');
    return loaded;
  }

  /**
   * The audit row, written BEFORE the action. If it cannot be written (for
   * example before migration 144), nothing happens: no unrecorded action.
   */
  private async audit(type: AuditType, facts: PaymentFacts, admin: AdminContext, reason: string) {
    const why = (reason ?? '').trim();
    if (why.length < 5) throw new BadRequestException('Say why, in a few words (at least 5 characters).');
    const dispute = activeDispute(facts);
    const { error } = await this.db.from('admin_finance_actions').insert({
      action_type: type,
      transaction_id: facts.tx.id,
      dispute_id: dispute?.id ?? null,
      admin_id: admin.id,
      admin_email: admin.email,
      admin_role: admin.role,
      reason: why.slice(0, 1000),
      previous_state: {
        transaction_status: facts.tx.status,
        escrow_status: facts.escrow?.status ?? null,
        completion_status: facts.completion?.status ?? null,
        post_status: facts.post?.status ?? null,
      },
    });
    if (error) {
      this.logger.error(`[ADMIN_PAYMENTS] audit ${type} tx=${facts.tx.id} not written: ${error.message}`);
      throw new ServiceUnavailableException('This action could not be recorded, so it was not taken. Please try again.');
    }
  }

  private async notifySafely(list: Parameters<NotificationsService['sendMany']>[0]) {
    try {
      await this.notifications.sendMany(list);
    } catch (e) {
      this.logger.warn(`[ADMIN_PAYMENTS] notification failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }

  private async load(txId: string): Promise<{ facts: PaymentFacts; raw: Row }> {
    const { data: tx, error } = await this.db.from('transactions')
      .select('id, post_id, buyer_user_id, phone, amount, fee, total_paid, status, mpesa_receipt, failure_reason, created_at')
      .eq('id', txId).maybeSingle();
    if (error) throw new ServiceUnavailableException('Could not read this payment right now.');
    if (!tx) throw new NotFoundException('Payment not found.');
    const postId = tx.post_id as string;

    const [postRes, attemptsRes, escrowRes, completionRes, disputesRes, advanceRes, eventsRes, actionsRes, receiptRes] = await Promise.all([
      this.db.from('posts')
        .select('id, title, type, category, location, price, status, created_at, author_user_id, selected_provider_id, archived_at')
        .eq('id', postId).maybeSingle(),
      this.db.from('transactions').select('id, status, total_paid, failure_reason, created_at')
        .eq('post_id', postId).order('created_at', { ascending: true }).limit(20),
      this.db.from('escrow').select('status, released_at, created_at').eq('transaction_id', txId).maybeSingle(),
      this.db.from('job_completions')
        .select('id, status, created_at, reviewed_at, auto_approve_at, approved_by, provider_user_id, client_user_id')
        .eq('post_id', postId).order('created_at', { ascending: false }).limit(1).maybeSingle(),
      this.db.from('disputes')
        .select('id, status, raised_by_role, opened_by_admin_id, provider_amount, buyer_refund, created_at, escalated_at, resolved_at')
        .eq('post_id', postId).order('created_at', { ascending: true }).limit(10),
      this.db.from('materials_advances').select('status, amount, failure_reason, release_requested_at, paid_out_at')
        .eq('transaction_id', txId).maybeSingle(),
      this.db.from('payout_audit_events').select('event_type, occurred_at, reason, metadata')
        .eq('transaction_id', txId).order('occurred_at', { ascending: true }).limit(50),
      this.db.from('admin_finance_actions').select('action_type, admin_email, admin_role, reason, created_at')
        .eq('transaction_id', txId).order('created_at', { ascending: true }).limit(50),
      this.db.from('payment_receipts').select('receipt_number').eq('transaction_id', txId).maybeSingle(),
    ]);
    // These decide which actions are offered. A failed read is never taken as
    // "nothing there": a missing dispute would offer a payout on a disputed job.
    const critical = { post: postRes, attempts: attemptsRes, escrow: escrowRes, completion: completionRes, disputes: disputesRes };
    for (const [name, res] of Object.entries(critical)) {
      if (res.error) {
        this.logger.error(`[ADMIN_PAYMENTS] tx=${txId} ${name} unreadable: ${res.error.message}`);
        throw new ServiceUnavailableException('Part of this payment could not be read, so nothing is shown. Please reload.');
      }
    }
    const post = (postRes.data as Row | null) ?? null;
    const disputes = ((disputesRes.data ?? []) as Row[]);

    let decisions: Row[] = [];
    if (disputes.length) {
      const { data, error: decisionsError } = await this.db.from('dispute_decisions').select('decision_type, decided_by_system, created_at')
        .in('dispute_id', disputes.map((d) => d.id)).order('created_at', { ascending: true });
      if (decisionsError) throw new ServiceUnavailableException('Part of this payment could not be read, so nothing is shown. Please reload.');
      decisions = (data ?? []) as Row[];
    }

    const ids = [post?.author_user_id, post?.selected_provider_id].filter((x): x is string => typeof x === 'string' && !!x);
    const people = new Map<string, Row>();
    if (ids.length) {
      const { data } = await this.db.from('users').select('id, name, email, phone_number, created_at').in('id', ids);
      for (const u of (data ?? []) as Row[]) people.set(u.id as string, u);
    }
    const person = (id: unknown) => (typeof id === 'string' && id ? people.get(id) ?? { id, name: null, email: null, phone_number: null } : null);

    const completion = (completionRes.data as Row | null) ?? null;
    const facts: PaymentFacts = {
      tx: {
        id: tx.id as string,
        status: tx.status as string,
        amount: (tx.amount as number | null) ?? null,
        total_paid: (tx.total_paid as number | null) ?? null,
        mpesa_receipt: (tx.mpesa_receipt as string | null) ?? null,
        failure_reason: (tx.failure_reason as string | null) ?? null,
        created_at: tx.created_at as string,
      },
      attempts: ((attemptsRes.data ?? []) as Row[]).map((a) => ({
        id: a.id, status: a.status, total_paid: a.total_paid ?? null, failure_reason: a.failure_reason ?? null, created_at: a.created_at,
      })),
      post: post
        ? {
            id: post.id, title: post.title ?? null, status: post.status ?? null, created_at: post.created_at ?? null,
            author_user_id: post.author_user_id ?? null, selected_provider_id: post.selected_provider_id ?? null,
          }
        : null,
      escrow: (escrowRes.data as PaymentFacts['escrow']) ?? null,
      completion: completion
        ? {
            id: completion.id, status: completion.status, created_at: completion.created_at, reviewed_at: completion.reviewed_at ?? null,
            auto_approve_at: completion.auto_approve_at ?? null, approved_by: completion.approved_by ?? null,
          }
        : null,
      disputes: disputes.map((d) => ({
        id: d.id, status: d.status, raised_by_role: d.raised_by_role ?? null, opened_by_admin_id: d.opened_by_admin_id ?? null,
        created_at: d.created_at, escalated_at: d.escalated_at ?? null, resolved_at: d.resolved_at ?? null,
      })),
      decisions: decisions.map((d) => ({ decision_type: d.decision_type, decided_by_system: d.decided_by_system ?? null, created_at: d.created_at })),
      advance: (advanceRes.data as PaymentFacts['advance']) ?? null,
      payoutEvents: (eventsRes.data ?? []) as PaymentFacts['payoutEvents'],
      // Before migration 144 the table already exists (117); a read error just shows no actions.
      adminActions: (actionsRes.data ?? []) as PaymentFacts['adminActions'],
    };

    return {
      facts,
      raw: {
        tx,
        post,
        completion,
        client: person(post?.author_user_id),
        provider: person(post?.selected_provider_id),
        advance: advanceRes.data ?? null,
        receiptNumber: (receiptRes.data?.receipt_number as string | undefined) ?? null,
        latestDisputeRow: disputes.at(-1) ?? null,
      },
    };
  }
}
