import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  InternalServerErrorException,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { randomUUID } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { EventsService } from '../events/events.service';
import { EVENT_TYPES } from '../events/event.types';
import { PayoutDestinationsService } from '../payouts/payout-destinations.service';
import { PayoutAuditService } from '../payouts/payout-audit.service';
import { explainFailure } from '../payouts/payout-destination.resolver';
import { normalizeMsisdn } from '../common/phone/msisdn';
import { B2cNotSentError, DarajaService } from './daraja.service';
import { calculateFee } from './fee';
import {
  ADVANCE_MIN_JOB_KES,
  ADVANCE_PERCENT,
  AdvanceRow,
  AdvanceUnavailableReason,
  advanceAmountFor,
  advanceEligibility,
  advanceEnabled,
  advancePaidOut,
  canRelease,
  isMissingTable,
  releaseRefusal,
} from './advance';

const COLUMNS =
  'id, transaction_id, post_id, client_user_id, provider_user_id, amount, status, conversation_id, ' +
  'originator_conversation_id, failure_reason, release_requested_at, paid_out_at';

const DISPUTE_TERMINAL = ['resolved', 'resolved_release', 'resolved_refund', 'resolved_partial', 'merged'];

/**
 * Materials Advance: the money moves (rules in advance.ts, table in migration 139).
 *
 * The advance is its OWN payout, beside the job's final one. It has its own
 * row, status and M-Pesa conversation ids, and every status change is a
 * compare-and-set on that row, so a release, an approval and a dispute that
 * arrive together cannot all act:
 *
 *   release (customer)  held -> sending       then B2C; result: paid_out, or back to held
 *   final payout        held -> cancelled     the full amount goes at the end instead
 *   dispute             held -> frozen        the ruling covers the full amount
 *
 * Whoever claims the row first decides. The others see it changed and act on
 * what it became: a final payout subtracts a paid_out advance, and refuses
 * (to be retried) while one is still sending, because its outcome is unknown.
 *
 * READS FAIL CLOSED. If the advance cannot be read, money paths refuse rather
 * than assume there is none (assuming would pay the 40% twice). The one
 * exception is a table that does not exist yet (migration 139 not applied),
 * which cannot hold an advance.
 */
@Injectable()
export class MaterialsAdvanceService {
  private readonly logger = new Logger(MaterialsAdvanceService.name);
  private readonly devForceSuccess =
    process.env.MPESA_DEV_FORCE_SUCCESS === 'true' && process.env.NODE_ENV !== 'production';

  constructor(
    private readonly supabase: SupabaseService,
    private readonly daraja: DarajaService,
    private readonly payoutDestinations: PayoutDestinationsService,
    private readonly payoutAudit: PayoutAuditService,
    private readonly notifications: NotificationsService,
    private readonly events: EventsService,
  ) {}

  get enabled(): boolean {
    return advanceEnabled();
  }

  // ── Reads ───────────────────────────────────────────────────────────────────

  /** The advance on a transaction, or null. Throws on any read error but a missing table. */
  async forTransaction(transactionId: string): Promise<AdvanceRow | null> {
    const { data, error } = await this.supabase.client
      .from('materials_advances')
      .select(COLUMNS)
      .eq('transaction_id', transactionId)
      .maybeSingle();
    if (error) {
      if (isMissingTable(error)) return null;
      throw new InternalServerErrorException(`Could not read the materials advance for ${transactionId}: ${error.message}`);
    }
    return (data as unknown as AdvanceRow | null) ?? null;
  }

  private async byConversation(conversationId?: string, originatorId?: string): Promise<AdvanceRow | null> {
    for (const [column, value] of [
      ['conversation_id', conversationId],
      ['originator_conversation_id', originatorId],
    ] as const) {
      if (!value) continue;
      const { data, error } = await this.supabase.client
        .from('materials_advances')
        .select(COLUMNS)
        .eq(column, value)
        .maybeSingle();
      if (error) {
        if (isMissingTable(error)) return null;
        throw new InternalServerErrorException(`Could not look up a materials advance: ${error.message}`);
      }
      if (data) return data as unknown as AdvanceRow;
    }
    return null;
  }

  /** An approved ID check (migration 135). */
  async providerIdVerified(providerUserId: string): Promise<boolean> {
    const { data, error } = await this.supabase.client.rpc('provider_vetting_state', { p_user_id: providerUserId });
    if (error) {
      this.logger.warn(`[ADVANCE] vetting state unavailable for ${providerUserId}: ${error.message}`);
      return false;
    }
    const row = Array.isArray(data) ? data[0] : data;
    return (row as { id_verified?: boolean } | null)?.id_verified === true;
  }

  private async activeDispute(postId: string): Promise<boolean> {
    const { data, error } = await this.supabase.client.from('disputes').select('status').eq('post_id', postId);
    if (error) throw new InternalServerErrorException(`Could not read disputes: ${error.message}`);
    return (data ?? []).some((d) => !DISPUTE_TERMINAL.includes((d as { status: string }).status));
  }

  // ── Offer (checkout) ────────────────────────────────────────────────────────

  /**
   * Can this job be paid with Materials Advance, and what would it look like?
   * For the payment screen; only the customer who posted the job may ask.
   */
  async quote(postId: string, userId: string): Promise<{
    available: boolean;
    reason: AdvanceUnavailableReason | null;
    min_job_amount: number;
    percent: number;
    job_amount: number;
    advance_amount: number;
    fee: number;
    total: number;
  }> {
    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, price, author_user_id, selected_provider_id')
      .eq('id', postId)
      .maybeSingle();
    if (!post) throw new NotFoundException('Job not found.');
    if (post.author_user_id !== userId) throw new ForbiddenException('Only the customer who posted this job can pay for it.');

    const jobAmount = Math.round(Number(post.price) || 0);
    const providerId = (post.selected_provider_id as string | null) ?? null;
    const verdict = advanceEligibility({
      enabled: this.enabled,
      jobAmount,
      providerIdVerified: providerId ? await this.providerIdVerified(providerId) : false,
    });
    const fee = jobAmount >= 100 ? calculateFee(jobAmount) : 0;
    return {
      available: verdict.eligible,
      reason: verdict.reason,
      min_job_amount: ADVANCE_MIN_JOB_KES,
      percent: ADVANCE_PERCENT,
      job_amount: jobAmount,
      advance_amount: verdict.eligible ? advanceAmountFor(jobAmount) : 0,
      fee,
      total: jobAmount + fee,
    };
  }

  /** initiatePayment, when the customer chose Materials Advance: refuse unless eligible. */
  async assertEligible(jobAmount: number, providerUserId: string): Promise<number> {
    const verdict = advanceEligibility({
      enabled: this.enabled,
      jobAmount,
      providerIdVerified: await this.providerIdVerified(providerUserId),
    });
    if (!verdict.eligible) {
      throw new BadRequestException(
        verdict.reason === 'too_small'
          ? `Materials Advance is for jobs of KES ${ADVANCE_MIN_JOB_KES.toLocaleString('en-KE')} or more.`
          : verdict.reason === 'provider_not_verified'
            ? 'Materials Advance is only available with a verified provider.'
            : 'Materials Advance is not available yet.',
      );
    }
    return advanceAmountFor(jobAmount);
  }

  /** Record the advance on a new transaction (before the STK prompt is sent). */
  async createForTransaction(input: {
    transactionId: string;
    postId: string;
    clientUserId: string;
    providerUserId: string;
    amount: number;
  }): Promise<void> {
    const { error } = await this.supabase.client.from('materials_advances').insert({
      transaction_id: input.transactionId,
      post_id: input.postId,
      client_user_id: input.clientUserId,
      provider_user_id: input.providerUserId,
      amount: input.amount,
      status: 'held',
    });
    if (error) throw new InternalServerErrorException(`Could not record the materials advance: ${error.message}`);
    this.logger.log(`[ADVANCE] offered tx=${input.transactionId} post=${input.postId} amount=${input.amount}`);
  }

  // ── Release (the customer's tap) ────────────────────────────────────────────

  async release(postId: string, clientUserId: string): Promise<{ status: string; amount: number; message: string }> {
    const { data: post } = await this.supabase.client
      .from('posts')
      .select('id, title, author_user_id, selected_provider_id')
      .eq('id', postId)
      .maybeSingle();
    if (!post) throw new NotFoundException('Job not found.');
    if (post.author_user_id !== clientUserId) {
      throw new ForbiddenException('Only the customer who paid can send the materials money.');
    }

    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('id, status')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (!tx) throw new BadRequestException(releaseRefusal('no_advance'));

    const row = await this.forTransaction(tx.id as string);
    const verdict = canRelease({ row, txStatus: tx.status as string, activeDispute: await this.activeDispute(postId) });
    if (!verdict.ok) throw new ConflictException(releaseRefusal(verdict.reason ?? 'not_held'));
    const advance = row as AdvanceRow;

    // The fundi it goes to is the one this advance was promised to.
    if (post.selected_provider_id !== advance.provider_user_id) {
      throw new ConflictException('The provider on this job changed after payment. Contact support to settle it.');
    }

    // Where it goes: the destination frozen on this job's escrow, exactly as
    // the final payout resolves it (MpesaService.releasePayout).
    const { data: escrowRow } = await this.supabase.client
      .from('escrow')
      .select('payout_destination_snapshot')
      .eq('transaction_id', advance.transaction_id)
      .maybeSingle();
    const resolved = await this.payoutDestinations.resolveForPayout({
      providerUserId: advance.provider_user_id,
      escrowSnapshot: this.payoutDestinations.parseSnapshot(escrowRow?.payout_destination_snapshot),
    });

    let phone: string | null;
    let destinationId: string | null = null;
    if (resolved.kind === 'paid') {
      phone = normalizeMsisdn(resolved.msisdn);
      destinationId = resolved.destinationId;
    } else if (this.payoutDestinations.isEnabled) {
      await this.payoutAudit.emit({
        providerUserId: advance.provider_user_id,
        eventType: 'payout_refused',
        actorType: 'system',
        transactionId: advance.transaction_id,
        reason: resolved.reason,
        metadata: { post_id: postId, kind: 'materials_advance', source: resolved.source },
      });
      throw new BadRequestException(explainFailure(resolved.reason));
    } else {
      const { data: providerUser } = await this.supabase.client
        .from('users')
        .select('phone_number')
        .eq('id', advance.provider_user_id)
        .maybeSingle();
      phone = normalizeMsisdn(providerUser?.phone_number as string | undefined);
    }
    if (!phone) throw new BadRequestException('Your provider has not added a valid M-Pesa number yet.');

    // Audit before money moves: a payout that cannot be recorded must not start.
    await this.payoutAudit.emitOrThrow({
      providerUserId: advance.provider_user_id,
      eventType: 'payout_initiated',
      actorType: 'system',
      payoutDestinationId: destinationId,
      transactionId: advance.transaction_id,
      normalizedDestination: phone,
      channel: 'mpesa',
      metadata: { post_id: postId, kind: 'materials_advance', amount: advance.amount, released_by: clientUserId },
    });

    // CLAIM. One conditional update decides between this tap, an approval
    // (held -> cancelled) and a dispute (held -> frozen).
    const now = new Date().toISOString();
    const { data: claimed, error: claimError } = await this.supabase.client
      .from('materials_advances')
      .update({ status: 'sending', release_requested_at: now, failure_reason: null, payout_destination_id: destinationId })
      .eq('id', advance.id)
      .eq('status', 'held')
      .select('id');
    if (claimError) throw new InternalServerErrorException(`Could not claim the materials advance: ${claimError.message}`);
    if (!claimed || claimed.length === 0) {
      void this.payoutAudit.emit({
        providerUserId: advance.provider_user_id,
        eventType: 'payout_refused',
        actorType: 'system',
        transactionId: advance.transaction_id,
        reason: 'payment_changed',
        metadata: { post_id: postId, kind: 'materials_advance' },
      });
      throw new ConflictException(releaseRefusal('not_held'));
    }

    let result: { conversationId: string; originatorConversationId: string };
    if (this.devForceSuccess) {
      result = { conversationId: `DEV_${randomUUID()}`, originatorConversationId: `DEV_${randomUUID()}` };
    } else {
      try {
        result = await this.daraja.b2cPayout({ phone, amount: advance.amount, jobId: postId });
      } catch (err) {
        const detail = (err instanceof Error ? err.message : String(err)).slice(0, 500);
        if (err instanceof B2cNotSentError) {
          // Certainly not sent: hold it again so the customer can retry.
          await this.supabase.client
            .from('materials_advances')
            .update({ status: 'held', failure_reason: detail })
            .eq('id', advance.id)
            .eq('status', 'sending');
          this.logger.error(`[ADVANCE][NOT_SENT] post=${postId} advance=${advance.id} ${detail}`);
          throw new BadRequestException('We could not send the materials money just now. Nothing was sent, so you can try again.');
        }
        // Outcome unknown (timeout, 5xx): M-Pesa may have taken it. Stay
        // 'sending' so nothing pays twice; the stuck-advance alert and the
        // Daraja portal decide what really happened.
        await this.supabase.client
          .from('materials_advances')
          .update({ failure_reason: `B2C outcome unknown: ${detail}`.slice(0, 500) })
          .eq('id', advance.id);
        this.logger.error(`[ADVANCE][OUTCOME_UNKNOWN] post=${postId} advance=${advance.id} left sending: ${detail}`);
        return {
          status: 'sending',
          amount: advance.amount,
          message: 'M-Pesa is confirming the materials payment. We will let you know as soon as it is through.',
        };
      }
    }

    await this.supabase.client
      .from('materials_advances')
      .update({ conversation_id: result.conversationId, originator_conversation_id: result.originatorConversationId })
      .eq('id', advance.id);

    void this.payoutAudit.emit({
      providerUserId: advance.provider_user_id,
      eventType: 'payout_sent_to_processor',
      actorType: 'system',
      payoutDestinationId: destinationId,
      transactionId: advance.transaction_id,
      normalizedDestination: phone,
      channel: 'mpesa',
      metadata: { post_id: postId, kind: 'materials_advance', amount: advance.amount, conversation_id: result.conversationId },
    });
    void this.events.emit({
      type: EVENT_TYPES.MATERIALS_ADVANCE_SENT,
      actorUserId: clientUserId,
      entityType: 'payment',
      entityId: advance.transaction_id,
      payload: { post_id: postId, advance_id: advance.id, amount: advance.amount, conversation_id: result.conversationId },
    });
    this.logger.log(`[ADVANCE][SENT] post=${postId} advance=${advance.id} amount=${advance.amount} conv=${result.conversationId}`);

    if (this.devForceSuccess) {
      await this.settleByConversation({ conversationId: result.conversationId, resultCode: 0, resultDesc: 'DEV SIMULATED SUCCESS', source: 'dev' });
    }
    return {
      status: 'sending',
      amount: advance.amount,
      message: 'The materials money is on its way to your provider. The rest stays held until you approve the work.',
    };
  }

  // ── B2C result ──────────────────────────────────────────────────────────────

  /**
   * Settle a B2C result that belongs to an advance. Returns false when the
   * conversation is not an advance (the caller then reports it unmatched).
   * Only a definitive result moves it, and only out of 'sending'.
   */
  async settleByConversation(input: {
    conversationId?: string;
    originatorConversationId?: string;
    resultCode: number;
    resultDesc: string;
    source: string;
  }): Promise<boolean> {
    const advance = await this.byConversation(input.conversationId, input.originatorConversationId);
    if (!advance) return false;
    if (advance.status !== 'sending') {
      this.logger.log(`[ADVANCE][SETTLE] advance=${advance.id} already '${advance.status}' (${input.source}); nothing to do`);
      return true;
    }

    const { data: post } = await this.supabase.client.from('posts').select('title').eq('id', advance.post_id).maybeSingle();
    const title = (post?.title as string | undefined) ?? 'your job';
    const kes = `KES ${advance.amount.toLocaleString('en-KE')}`;

    if (input.resultCode === 0) {
      const { data: moved } = await this.supabase.client
        .from('materials_advances')
        .update({ status: 'paid_out', paid_out_at: new Date().toISOString(), failure_reason: null })
        .eq('id', advance.id)
        .eq('status', 'sending')
        .select('id');
      if (!moved || moved.length === 0) return true;

      void this.payoutAudit.emit({
        providerUserId: advance.provider_user_id,
        eventType: 'payout_completed',
        actorType: 'processor',
        transactionId: advance.transaction_id,
        metadata: { post_id: advance.post_id, kind: 'materials_advance', amount: advance.amount, source: input.source },
      });
      void this.events.emit({
        type: EVENT_TYPES.MATERIALS_ADVANCE_PAID_OUT,
        entityType: 'payment',
        entityId: advance.transaction_id,
        payload: { post_id: advance.post_id, advance_id: advance.id, amount: advance.amount },
      });
      this.logger.log(`[ADVANCE][PAID_OUT] advance=${advance.id} post=${advance.post_id} amount=${advance.amount}`);
      await this.notifications.sendMany([
        {
          userId: advance.provider_user_id,
          type: 'payment_secured',
          title: 'Materials money sent',
          body: `${kes} for "${title}" is on your M-Pesa. Buy the materials for this job; the rest is paid when the customer approves the work.`,
          data: { post_id: advance.post_id },
        },
        {
          userId: advance.client_user_id,
          type: 'payment_secured',
          title: 'Materials money delivered',
          body: `${kes} reached your provider for "${title}". The rest stays held until you approve the work.`,
          data: { post_id: advance.post_id },
        },
      ]);
      return true;
    }

    // Failed: nothing reached the fundi. Hold it again, unless a dispute froze
    // the payment meanwhile, in which case the ruling covers the full amount.
    const { data: tx } = await this.supabase.client
      .from('transactions')
      .select('status')
      .eq('id', advance.transaction_id)
      .maybeSingle();
    const next = tx?.status === 'paid' ? 'held' : 'frozen';
    await this.supabase.client
      .from('materials_advances')
      .update({ status: next, failure_reason: (input.resultDesc || 'M-Pesa payout failed').slice(0, 500) })
      .eq('id', advance.id)
      .eq('status', 'sending');
    void this.payoutAudit.emit({
      providerUserId: advance.provider_user_id,
      eventType: 'payout_failed',
      actorType: 'processor',
      transactionId: advance.transaction_id,
      reason: input.resultDesc?.slice(0, 200) || 'b2c_failure',
      metadata: { post_id: advance.post_id, kind: 'materials_advance', source: input.source, now: next },
    });
    this.logger.warn(`[ADVANCE][FAILED] advance=${advance.id} -> ${next}: ${input.resultDesc}`);
    if (next === 'held') {
      await this.notifications.send({
        userId: advance.client_user_id,
        type: 'materials_advance_failed',
        title: 'Materials money not sent',
        body: `M-Pesa could not deliver ${kes} to your provider for "${title}". Nothing left Help24, and you can try again from the job.`,
        data: { post_id: advance.post_id },
      });
    }
    return true;
  }

  // ── The final payout and disputes ───────────────────────────────────────────

  /**
   * Called by MpesaService.releasePayout BEFORE it claims the transaction.
   * Returns what the advance already paid, which the final payout subtracts.
   * A held advance is cancelled first (the full amount goes at the end); one
   * still sending makes the payout refuse, so the event retry comes back once
   * M-Pesa has answered.
   */
  async prepareFinalPayout(transactionId: string): Promise<number> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const row = await this.forTransaction(transactionId);
      if (!row) return 0;
      if (row.status === 'sending') {
        throw new ConflictException(
          'The materials advance on this job is still being confirmed by M-Pesa. The final payout waits for it and will retry.',
        );
      }
      if (row.status !== 'held') return advancePaidOut(row);
      const { data: cancelled, error } = await this.supabase.client
        .from('materials_advances')
        .update({ status: 'cancelled' })
        .eq('id', row.id)
        .eq('status', 'held')
        .select('id');
      if (error) throw new InternalServerErrorException(`Could not settle the materials advance: ${error.message}`);
      if (cancelled && cancelled.length > 0) {
        this.logger.log(`[ADVANCE] cancelled unsent advance=${row.id}: the final payout carries the full amount`);
        return 0;
      }
      // Lost the claim (a release started this instant): read again.
    }
    throw new ConflictException('The materials advance changed while the payout started. It will retry.');
  }

  /** Called when a dispute freezes the payment. Never blocks the dispute. */
  async freezeForDispute(transactionId: string): Promise<void> {
    const { error } = await this.supabase.client
      .from('materials_advances')
      .update({ status: 'frozen' })
      .eq('transaction_id', transactionId)
      .eq('status', 'held');
    if (error && !isMissingTable(error)) {
      this.logger.error(`[ADVANCE] freeze failed for tx=${transactionId}: ${error.message}`);
    }
  }
}
