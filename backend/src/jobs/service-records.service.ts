import {
  BadRequestException,
  ForbiddenException,
  Injectable,
  InternalServerErrorException,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { deriveSettlementState, SettlementState } from './settlement-state';

/**
 * Service Records — the READ layer over Help24's existing job constellation.
 *
 * This service introduces NO new concept of a job. A "service record" is the
 * post plus the transaction, escrow, completion and dispute rows that already
 * hang off it; `deriveSettlementState()` remains the ONE money state machine and
 * is called here rather than reimplemented. Nothing in this file writes to
 * posts, transactions, escrow, job_completions or disputes — the only write it
 * ever performs is allocating a receipt number (see `resolveReceipt`).
 *
 * Why this lives on the server at all, rather than in the Flutter client:
 *   1. `job_completions` and `disputes` are RLS service-role-only, so a device
 *      physically cannot read the provider side of its own work history.
 *   2. Deriving settlement state on the device would fork the state machine.
 * Both are load-bearing; see the architecture note in settlement-state.ts.
 */

export type ReceiptStatus =
  | 'PAID'
  | 'ESCROWED'
  | 'RELEASED'
  | 'REFUNDED'
  | 'PARTIALLY_REFUNDED'
  | 'DISPUTED'
  | 'UNDER_REVIEW';

export type ViewerRole = 'client' | 'provider';

interface CounterParty {
  user_id: string | null;
  name: string | null;
}

export interface ServiceRecordSummary {
  post_id: string;
  title: string;
  category: string | null;
  location: string | null;
  post_status: string;
  archived: boolean;
  viewer_role: ViewerRole;
  counterparty: CounterParty;
  amount: number | null;
  total_paid: number | null;
  currency: 'KES';
  payment_method: string | null;
  settlement_state: string;
  settlement_label: string;
  attention_required: boolean;
  receipt_available: boolean;
  created_at: string | null;
  completed_at: string | null;
  settled_at: string | null;
}

/** Transaction statuses for which money has demonstrably left the customer. */
const RECEIPTABLE_TX_STATUSES = ['paid', 'payout_pending', 'released', 'disputed', 'refunded'];

/** Mirrors the terminal set used by getLifecycle + archivePost. Kept identical. */
const DISPUTE_TERMINAL = ['resolved', 'resolved_release', 'resolved_refund', 'resolved_partial', 'merged'];

@Injectable()
export class ServiceRecordsService {
  private readonly logger = new Logger(ServiceRecordsService.name);

  constructor(private readonly supabase: SupabaseService) {}

  // ── History list ───────────────────────────────────────────────────────────

  /**
   * A user's service records, from either side of the transaction.
   *
   * A record exists from the moment a provider is SELECTED — that is the point
   * the conceptual model says the job comes into being, and it is the only
   * moment that is true for both parties at once. Open posts with no provider
   * are listings, not services, and belong in My Posts.
   *
   * Archived posts ARE included. Archiving is a soft delete that removes a post
   * from the feed; it does not unmake a service that was paid for, and the
   * record is permanent by design. `archived` is surfaced so the UI can say so.
   *
   * Cost is a fixed SIX queries regardless of page size — never N+1.
   */
  async listHistory(
    userId: string,
    role: ViewerRole,
    opts: { limit?: number; offset?: number } = {},
  ): Promise<{
    records: ServiceRecordSummary[];
    total_completed: number;
    completed_value: number;
    has_more: boolean;
  }> {
    if (!userId) throw new BadRequestException('user_id is required.');
    if (role !== 'client' && role !== 'provider') {
      throw new BadRequestException("role must be 'client' or 'provider'.");
    }

    const limit = Math.min(Math.max(opts.limit ?? 30, 1), 100);
    const offset = Math.max(opts.offset ?? 0, 0);

    // ── 1. The posts this user is a party to ────────────────────────────────
    const ownerColumn = role === 'client' ? 'author_user_id' : 'selected_provider_id';
    let query = this.supabase.client
      .from('posts')
      .select(
        'id, title, category, location, price, status, author_user_id, selected_provider_id, created_at, archived_at',
      )
      .eq(ownerColumn, userId);

    // A client's history is the set of their posts that reached a provider. For
    // the provider side the selected_provider_id filter already implies it.
    if (role === 'client') query = query.not('selected_provider_id', 'is', null);

    const { data: posts, error: postsErr } = await query
      .order('created_at', { ascending: false })
      .range(offset, offset + limit); // +1 row to detect has_more

    if (postsErr) {
      this.logger.error(`[SERVICE_RECORDS] posts query failed: ${postsErr.message}`);
      throw new InternalServerErrorException('Failed to load service history.');
    }

    const rows = posts ?? [];
    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    if (page.length === 0) {
      return { records: [], total_completed: 0, completed_value: 0, has_more: false };
    }

    const postIds = page.map((p) => p.id as string);

    // ── 2-6. Everything else, batched ───────────────────────────────────────
    const [txByPost, completionByPost, disputeByPost, nameById] = await Promise.all([
      this.latestTransactionsByPost(postIds),
      this.latestCompletionsByPost(postIds),
      this.latestDisputesByPost(postIds),
      this.namesFor(
        page.map((p) =>
          role === 'client' ? (p.selected_provider_id as string | null) : (p.author_user_id as string | null),
        ),
      ),
    ]);

    const txIds = [...txByPost.values()].map((t) => t.id as string);
    const [escrowByTx, receiptByTx] = await Promise.all([
      this.escrowByTransaction(txIds),
      this.receiptsByTransaction(txIds),
    ]);

    const disputeIds = [...disputeByPost.values()].map((d) => d.id as string);
    const decisionByDispute = await this.latestDecisionByDispute(disputeIds);

    // ── Assemble ────────────────────────────────────────────────────────────
    const records: ServiceRecordSummary[] = page.map((post) => {
      const postId = post.id as string;
      const tx = txByPost.get(postId) ?? null;
      const escrow = tx ? (escrowByTx.get(tx.id as string) ?? null) : null;
      const completion = completionByPost.get(postId) ?? null;
      const dispute = disputeByPost.get(postId) ?? null;
      const decision = dispute ? (decisionByDispute.get(dispute.id as string) ?? null) : null;
      const receipt = tx ? (receiptByTx.get(tx.id as string) ?? null) : null;

      const settlement = this.deriveFor({ tx, escrow, dispute, decision });

      const counterpartyId =
        role === 'client'
          ? (post.selected_provider_id as string | null)
          : (post.author_user_id as string | null);

      return {
        post_id: postId,
        title: (post.title as string) ?? 'Service',
        category: (post.category as string | null) ?? null,
        location: (post.location as string | null) ?? null,
        post_status: (post.status as string) ?? 'open',
        archived: post.archived_at != null,
        viewer_role: role,
        counterparty: {
          user_id: counterpartyId,
          name: counterpartyId ? (nameById.get(counterpartyId) ?? null) : null,
        },
        // Falls back to the agreed post price when no payment exists yet, so a
        // selected-but-unpaid job still shows what was agreed rather than a
        // blank. Never invents a figure that was not agreed or charged.
        amount: (tx?.amount as number | null) ?? (post.price != null ? Number(post.price) : null),
        total_paid: (tx?.total_paid as number | null) ?? null,
        currency: 'KES',
        payment_method: receipt ? (receipt.payment_method as string) : tx ? 'mpesa' : null,
        settlement_state: settlement.state,
        settlement_label: settlement.label,
        attention_required: settlement.attention_required,
        // Advisory only — the receipt endpoint re-checks before issuing.
        receipt_available: !!tx && RECEIPTABLE_TX_STATUSES.includes(tx.status as string),
        created_at: (post.created_at as string | null) ?? null,
        completed_at:
          completion?.status === 'approved' ? ((completion.reviewed_at as string | null) ?? null) : null,
        settled_at: (escrow?.released_at as string | null) ?? null,
      };
    });

    // ── Work completed, NOT money settled ───────────────────────────────────
    // Counted from an APPROVED completion, not from settlement_state. Those are
    // different facts and conflating them lies to the provider: production
    // currently holds six approved completions and zero released payouts, so a
    // settlement-based count would tell a provider who finished six jobs that
    // they have finished none. A payout stuck in payout_pending is a payments
    // problem; it does not un-do the work.
    //
    // `completed_value` is the agreed value of that completed work — deliberately
    // NOT called earnings and NOT a balance. It says nothing about what has
    // actually been paid out, because this is a work history, not an accounting
    // system (Phase 6). Counted over the page so it always agrees with what is
    // on screen rather than quietly summing rows the user cannot see.
    const completedRecords = records.filter((r) => r.completed_at != null);
    const completedValue = completedRecords.reduce((sum, r) => sum + (r.amount ?? 0), 0);

    return {
      records,
      total_completed: completedRecords.length,
      completed_value: completedValue,
      has_more: hasMore,
    };
  }

  // ── Receipt ────────────────────────────────────────────────────────────────

  /**
   * The Help24 platform receipt for a job.
   *
   * Allocation is lazy and idempotent: the row is created on first request and
   * the UNIQUE constraint on transaction_id makes a concurrent or retried call
   * return the existing number rather than minting a second one. A number is
   * only ever burned once money has actually moved — a pending or failed
   * payment gets an honest unavailable-reason instead, never a receipt.
   *
   * Amounts and status are read LIVE (never cached on the receipt row), so a
   * receipt opened before and after a payout tells the truth both times.
   */
  async getReceipt(postId: string, userId: string) {
    if (!userId) throw new BadRequestException('user_id is required.');

    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, title, description, category, location, author_user_id, selected_provider_id, created_at')
      .eq('id', postId)
      .single();
    if (!post) throw new NotFoundException(`Post ${postId} not found.`);

    const authorId = post.author_user_id as string;
    const providerId = (post.selected_provider_id as string | null) ?? '';
    const isClient = userId === authorId;
    const isProvider = providerId !== '' && userId === providerId;
    // Identical participant gate to getLifecycle. A receipt names both parties
    // and the amount they exchanged; nobody else may read it.
    if (!isClient && !isProvider) {
      throw new ForbiddenException('Only the client or selected provider can view this receipt.');
    }

    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('id, status, amount, fee, total_paid, mpesa_receipt, failure_reason, created_at')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    // ── Not receiptable yet — say why, truthfully (Phase 7) ─────────────────
    if (!tx) {
      return this.unavailable('no_payment', 'No payment has been made for this service yet.');
    }
    if (tx.status === 'pending') {
      return this.unavailable(
        'payment_pending',
        'Payment is still being confirmed. Your receipt will be available once it completes.',
      );
    }
    if (!RECEIPTABLE_TX_STATUSES.includes(tx.status as string)) {
      return this.unavailable(
        'payment_failed',
        (tx.failure_reason as string | null) ?? 'This payment did not complete, so no receipt was issued.',
      );
    }

    const receipt = await this.resolveReceipt(tx.id as string, postId);

    // ── Live settlement — never a cached status ─────────────────────────────
    const { data: escrow } = await this.supabase.client
      .from('escrow')
      .select('status, released_at')
      .eq('transaction_id', tx.id as string)
      .maybeSingle();

    const { data: dispute } = await this.supabase.client
      .from('disputes')
      .select('id, status, provider_amount, buyer_refund, created_at, resolved_at')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    let decision: Record<string, unknown> | null = null;
    if (dispute) {
      const { data: decs } = await this.supabase.client
        .from('dispute_decisions')
        .select('decision_type, provider_amount, client_refund_amount, created_at')
        .eq('dispute_id', dispute.id as string)
        .order('created_at', { ascending: true });
      decision = decs && decs.length > 0 ? (decs[decs.length - 1] as Record<string, unknown>) : null;
    }

    const settlement = this.deriveFor({ tx, escrow, dispute, decision });

    const [clientName, providerName] = await Promise.all([
      this.nameOf(authorId),
      providerId ? this.nameOf(providerId) : Promise.resolve(null),
    ]);

    const refunded = settlement.amounts.client_refund;

    return {
      available: true as const,
      receipt_number: receipt.receipt_number,
      issued_at: receipt.issued_at,

      // Help24's own transaction id — distinct from the M-Pesa reference below.
      transaction_id: tx.id,
      post_id: postId,

      service: {
        title: (post.title as string) ?? 'Service',
        description: (post.description as string | null) ?? null,
        category: (post.category as string | null) ?? null,
        location: (post.location as string | null) ?? null,
      },

      // Names only. Phone numbers are deliberately NOT on the receipt: the
      // existing product never exposes a counterparty's number here.
      customer_name: clientName,
      provider_name: providerName,

      payment_method: receipt.payment_method,
      // The underlying mobile-money reference, and ONLY for the party who paid.
      // Mirrors the existing rule in getLifecycle — a provider never sees the
      // client's M-Pesa receipt. Null for the provider is not a missing value;
      // `provider_reference_visible` says so explicitly.
      provider_reference: isClient ? ((tx.mpesa_receipt as string | null) ?? null) : null,
      provider_reference_visible: isClient,

      currency: 'KES' as const,
      amount: (tx.amount as number | null) ?? null,
      platform_fee: (tx.fee as number | null) ?? null,
      total_paid: (tx.total_paid as number | null) ?? null,
      refunded_amount: refunded,

      status: this.receiptStatus(settlement),
      status_explanation: settlement.explanation,
      paid_at: (tx.created_at as string | null) ?? null,
      settled_at: (escrow?.released_at as string | null) ?? null,

      viewer_role: isClient ? ('client' as const) : ('provider' as const),
    };
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private unavailable(reason: string, message: string) {
    return { available: false as const, reason, message };
  }

  /**
   * Fetch-or-allocate, in that order. The SELECT-first path means the common
   * case (an already-issued receipt) performs no write at all and burns no
   * sequence value.
   */
  private async resolveReceipt(
    transactionId: string,
    postId: string,
  ): Promise<{ receipt_number: string; issued_at: string; payment_method: string }> {
    const existing = await this.supabase.client
      .from('payment_receipts')
      .select('receipt_number, issued_at, payment_method')
      .eq('transaction_id', transactionId)
      .maybeSingle();

    if (existing.data) {
      return existing.data as { receipt_number: string; issued_at: string; payment_method: string };
    }

    // receipt_number and payment_method come from column DEFAULTs, so the number
    // is allocated inside the INSERT and cannot be duplicated by a racing caller.
    const inserted = await this.supabase.client
      .from('payment_receipts')
      .insert({ transaction_id: transactionId, post_id: postId })
      .select('receipt_number, issued_at, payment_method')
      .maybeSingle();

    if (inserted.data) {
      this.logger.log(
        `[SERVICE_RECORDS][RECEIPT_ISSUED] tx=${transactionId} number=${
          (inserted.data as { receipt_number: string }).receipt_number
        }`,
      );
      return inserted.data as { receipt_number: string; issued_at: string; payment_method: string };
    }

    // Lost the race (23505 on transaction_id) — the winner's row is the answer.
    const afterRace = await this.supabase.client
      .from('payment_receipts')
      .select('receipt_number, issued_at, payment_method')
      .eq('transaction_id', transactionId)
      .maybeSingle();

    if (afterRace.data) {
      return afterRace.data as { receipt_number: string; issued_at: string; payment_method: string };
    }

    this.logger.error(
      `[SERVICE_RECORDS][RECEIPT_FAILED] tx=${transactionId} err=${inserted.error?.message ?? 'unknown'}`,
    );
    throw new InternalServerErrorException('Could not issue a receipt for this payment.');
  }

  /** Maps the canonical settlement state onto the receipt vocabulary. */
  private receiptStatus(s: SettlementState): ReceiptStatus {
    switch (s.state) {
      case 'released':
        return 'RELEASED';
      case 'refunded':
        return 'REFUNDED';
      case 'split_settled':
        return 'PARTIALLY_REFUNDED';
      case 'disputed':
        return 'DISPUTED';
      case 'in_escrow':
      case 'payout_processing':
      case 'settlement_failed':
        return 'ESCROWED';
      // 'inconsistent' must not be dressed up as a clean state. Support sees the
      // same flag the lifecycle screen raises.
      case 'inconsistent':
        return 'UNDER_REVIEW';
      default:
        return 'PAID';
    }
  }

  /** One derivation path shared by the list and the receipt. */
  private deriveFor(i: {
    tx: Record<string, unknown> | null;
    escrow: Record<string, unknown> | null;
    dispute: Record<string, unknown> | null;
    decision: Record<string, unknown> | null;
  }): SettlementState {
    const activeDispute = i.dispute != null && !DISPUTE_TERMINAL.includes(i.dispute.status as string);
    return deriveSettlementState({
      txStatus: (i.tx?.status as string | null) ?? null,
      escrowStatus: (i.escrow?.status as string | null) ?? null,
      failureReason: (i.tx?.failure_reason as string | null) ?? null,
      activeDispute,
      latestDecisionType: (i.decision?.decision_type as string | null) ?? null,
      amount: (i.tx?.amount as number | null) ?? null,
      fee: (i.tx?.fee as number | null) ?? null,
      totalPaid: (i.tx?.total_paid as number | null) ?? null,
      providerAmount:
        (i.decision?.provider_amount as number | null) ?? (i.dispute?.provider_amount as number | null) ?? null,
      clientRefund:
        (i.decision?.client_refund_amount as number | null) ?? (i.dispute?.buyer_refund as number | null) ?? null,
      paidAt: (i.tx?.created_at as string | null) ?? null,
      releasedAt: (i.escrow?.released_at as string | null) ?? null,
      disputedAt: (i.dispute?.created_at as string | null) ?? null,
      resolvedAt: (i.dispute?.resolved_at as string | null) ?? null,
    });
  }

  // ── Batched lookups (each is ONE query, whatever the page size) ────────────

  private async latestTransactionsByPost(postIds: string[]) {
    const out = new Map<string, Record<string, unknown>>();
    if (postIds.length === 0) return out;
    const { data } = await this.supabase.client
      .from('transactions')
      .select('id, post_id, status, amount, fee, total_paid, failure_reason, created_at')
      .in('post_id', postIds)
      .order('created_at', { ascending: false });
    // Ordered newest-first, so the first row seen for a post is its latest —
    // the same "latest transaction wins" rule getLifecycle applies.
    for (const row of data ?? []) {
      const pid = row.post_id as string;
      if (!out.has(pid)) out.set(pid, row as Record<string, unknown>);
    }
    return out;
  }

  private async escrowByTransaction(txIds: string[]) {
    const out = new Map<string, Record<string, unknown>>();
    if (txIds.length === 0) return out;
    const { data } = await this.supabase.client
      .from('escrow')
      .select('transaction_id, status, released_at')
      .in('transaction_id', txIds);
    for (const row of data ?? []) out.set(row.transaction_id as string, row as Record<string, unknown>);
    return out;
  }

  private async receiptsByTransaction(txIds: string[]) {
    const out = new Map<string, Record<string, unknown>>();
    if (txIds.length === 0) return out;
    const { data, error } = await this.supabase.client
      .from('payment_receipts')
      .select('transaction_id, receipt_number, payment_method')
      .in('transaction_id', txIds);
    // The list must not fail because receipts are unavailable — the history is
    // readable without them, and the receipt endpoint issues on demand anyway.
    if (error) {
      this.logger.warn(`[SERVICE_RECORDS] receipts lookup skipped: ${error.message}`);
      return out;
    }
    for (const row of data ?? []) out.set(row.transaction_id as string, row as Record<string, unknown>);
    return out;
  }

  private async latestCompletionsByPost(postIds: string[]) {
    const out = new Map<string, Record<string, unknown>>();
    if (postIds.length === 0) return out;
    const { data } = await this.supabase.client
      .from('job_completions')
      .select('post_id, status, reviewed_at, created_at')
      .in('post_id', postIds)
      .order('created_at', { ascending: false });
    for (const row of data ?? []) {
      const pid = row.post_id as string;
      if (!out.has(pid)) out.set(pid, row as Record<string, unknown>);
    }
    return out;
  }

  private async latestDisputesByPost(postIds: string[]) {
    const out = new Map<string, Record<string, unknown>>();
    if (postIds.length === 0) return out;
    const { data } = await this.supabase.client
      .from('disputes')
      .select('id, post_id, status, provider_amount, buyer_refund, created_at, resolved_at')
      .in('post_id', postIds)
      .order('created_at', { ascending: false });
    for (const row of data ?? []) {
      const pid = row.post_id as string;
      if (!out.has(pid)) out.set(pid, row as Record<string, unknown>);
    }
    return out;
  }

  private async latestDecisionByDispute(disputeIds: string[]) {
    const out = new Map<string, Record<string, unknown>>();
    if (disputeIds.length === 0) return out;
    const { data } = await this.supabase.client
      .from('dispute_decisions')
      .select('dispute_id, decision_type, provider_amount, client_refund_amount, created_at')
      .in('dispute_id', disputeIds)
      .order('created_at', { ascending: true });
    // Ascending, so the LAST row written for a dispute wins — matching
    // getLifecycle, which takes decisions[decisions.length - 1].
    for (const row of data ?? []) out.set(row.dispute_id as string, row as Record<string, unknown>);
    return out;
  }

  private async namesFor(ids: Array<string | null>) {
    const out = new Map<string, string>();
    const unique = [...new Set(ids.filter((i): i is string => !!i))];
    if (unique.length === 0) return out;
    const { data } = await this.supabase.client.from('users').select('id, name').in('id', unique);
    for (const row of data ?? []) out.set(row.id as string, (row.name as string | null) ?? '');
    return out;
  }

  private async nameOf(userId: string): Promise<string | null> {
    const { data } = await this.supabase.client
      .from('users')
      .select('name')
      .eq('id', userId)
      .maybeSingle();
    const name = (data?.name as string | null) ?? null;
    return name && name.trim() !== '' ? name : null;
  }
}
