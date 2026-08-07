import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { TransactionsService } from '../transactions/transactions.service';
import { NotificationsService } from '../notifications/notifications.service';
import { DarajaService } from './daraja.service';
import { EventsService } from '../events/events.service';
import { EVENT_TYPES } from '../events/event.types';
import { calculateFee, calculateTotal } from './fee';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ReleasePayoutDto } from './dto/release-payout.dto';
import { randomUUID } from 'crypto';

import { normalizeMsisdn } from '../common/phone/msisdn';
import { PayoutDestinationsService } from '../payouts/payout-destinations.service';
import { PayoutAuditService } from '../payouts/payout-audit.service';
import { explainFailure } from '../payouts/payout-destination.resolver';

/**
 * A Daraja STK callback reduced to the fields consumers need. All STK pushes
 * (escrow AND promotion purchases) share the single MPESA_CALLBACK_URL, so
 * /mpesa/stk-callback is a router: escrow transactions are matched first; a
 * callback matching no transaction is offered to registered fallback consumers
 * (see registerStkCallbackFallback).
 */
export interface ParsedStkCallback {
  checkoutRequestId: string;
  resultCode: number;
  resultDesc: string;
  receipt: string | null;
  amount: number | null;
}

export interface StkCallbackFallback {
  /** Stable name for log lines. */
  name: string;
  /** Returns true when the callback was claimed (matched a record it owns). */
  handle: (parsed: ParsedStkCallback) => Promise<boolean>;
}

/**
 * Normalizes a raw Kenyan phone number to the canonical `254XXXXXXXXX` form.
 *
 * Re-exported from the shared definition rather than restated: this string is
 * handed to Daraja B2C, and a second copy that drifts pays the wrong person.
 * See `src/common/phone/msisdn.ts`.
 */
const normalizePhone = normalizeMsisdn;

@Injectable()
export class MpesaService {
  private readonly logger = new Logger(MpesaService.name);

  /**
   * DEV-ONLY payment simulation. When enabled, STK push / B2C payout initiation
   * skips the external Daraja API and instead feeds a simulated SUCCESS callback
   * into the REAL handlers — so escrow/transaction transitions, events and
   * notifications all run exactly as in production. It bypasses ONLY the external
   * HTTP call, never any business logic. Defaults to false and is hard-blocked in
   * production (see constructor).
   */
  private readonly devForceSuccess: boolean;

  /** Fallback consumers for STK callbacks that match no escrow transaction. */
  private readonly stkCallbackFallbacks: StkCallbackFallback[] = [];

  constructor(
    private readonly daraja: DarajaService,
    private readonly transactions: TransactionsService,
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly events: EventsService,
    private readonly payoutDestinations: PayoutDestinationsService,
    private readonly payoutAudit: PayoutAuditService,
  ) {
    // NON-NEGOTIABLE hard block: dev payment simulation must never run in production.
    if (process.env.MPESA_DEV_FORCE_SUCCESS === 'true' && process.env.NODE_ENV === 'production') {
      throw new Error('Dev payment mode is not allowed in production');
    }
    // Only active outside production AND when explicitly opted in. Default: false.
    this.devForceSuccess =
      process.env.MPESA_DEV_FORCE_SUCCESS === 'true' && process.env.NODE_ENV !== 'production';
    if (this.devForceSuccess) {
      this.logger.warn(
        '[MPESA][DEV MODE ACTIVE] Payment is being simulated — no real Daraja API calls will be made',
      );
    }
  }

  // ── DEV-ONLY payment simulation helpers ─────────────────────────────────────
  // Build the exact Daraja callback shapes the real handlers parse, so the
  // simulated success path runs the full business pipeline. Only the external
  // Daraja HTTP call is skipped — no business logic is bypassed.

  private buildSimulatedStkCallback(checkoutRequestId: string, amount: number): Record<string, unknown> {
    return {
      Body: {
        stkCallback: {
          CheckoutRequestID: checkoutRequestId,
          ResultCode: 0,
          ResultDesc: 'DEV SIMULATED SUCCESS',
          CallbackMetadata: {
            Item: [
              { Name: 'Amount', Value: amount },
              { Name: 'MpesaReceiptNumber', Value: `DEV${randomUUID().replace(/-/g, '').slice(0, 10).toUpperCase()}` },
              { Name: 'PhoneNumber', Value: 254700000000 },
            ],
          },
        },
      },
    };
  }

  private buildSimulatedB2cCallback(conversationId: string): Record<string, unknown> {
    return {
      Result: {
        ResultCode: 0,
        ResultDesc: 'DEV SIMULATED SUCCESS',
        ConversationID: conversationId,
      },
    };
  }

  // ── Initiate STK push ──────────────────────────────────────────────────────

  async initiatePayment(dto: InitiatePaymentDto) {
    this.logger.log(`[PAY] ▶ initiate — post=${dto.post_id} buyer=${dto.buyer_user_id}`);

    const { data: post, error: postError } = await this.supabase.client
      .from('posts')
      .select('id, price, selected_provider_id')
      .eq('id', dto.post_id)
      .single();

    if (postError || !post) {
      throw new NotFoundException(`Post ${dto.post_id} not found.`);
    }

    if (!post.selected_provider_id) {
      throw new BadRequestException('No provider has been selected for this service yet.');
    }

    const amount = Math.round(Number(post.price));
    this.logger.log(`[PAY] Amount = KES ${amount}`);
    if (amount < 100) {
      throw new BadRequestException(
        'Service price is below the minimum payment threshold (KES 100).',
      );
    }

    const { data: existingTx } = await this.supabase.client
      .from('transactions')
      .select('id, status')
      .eq('post_id', dto.post_id)
      .in('status', ['pending', 'paid'])
      .maybeSingle();

    if (existingTx) {
      throw new ConflictException(
        existingTx.status === 'paid'
          ? 'Payment has already been made for this service.'
          : 'A payment is already in progress for this service.',
      );
    }

    const { data: buyerUser } = await this.supabase.client
      .from('users')
      .select('phone_number')
      .eq('id', dto.buyer_user_id)
      .maybeSingle();

    const buyerPhone = normalizePhone(buyerUser?.phone_number);
    if (!buyerPhone) {
      throw new BadRequestException(
        'Please add your M-Pesa number to your profile to make payments.',
      );
    }

    const { data: providerUser } = await this.supabase.client
      .from('users')
      .select('phone_number')
      .eq('id', post.selected_provider_id)
      .maybeSingle();

    const providerPhone = normalizePhone(providerUser?.phone_number);
    if (!providerPhone) {
      throw new BadRequestException(
        "The selected provider hasn't added their M-Pesa number yet. Ask them to update their profile.",
      );
    }

    const fee = calculateFee(amount);
    const totalPaid = calculateTotal(amount);
    this.logger.log(`[PAY] fee=${fee} totalPaid=${totalPaid}`);

    const transaction = await this.transactions.create({
      postId: dto.post_id,
      buyerUserId: dto.buyer_user_id,
      phone: buyerPhone,
      amount,
      fee,
      totalPaid,
    });

    // Audit: payment flow started.
    void this.events.emit({
      type: EVENT_TYPES.PAYMENT_INITIATED,
      actorUserId: dto.buyer_user_id,
      entityType: 'payment',
      entityId: transaction.id,
      payload: { post_id: dto.post_id, transaction_id: transaction.id, amount },
    });

    let stkResult: { checkoutRequestId: string; customerMessage: string };
    if (this.devForceSuccess) {
      // DEV MODE: skip Daraja entirely. A simulated SUCCESS callback is fired
      // below (after escrow is created) so the real pipeline runs end-to-end.
      stkResult = { checkoutRequestId: `DEV_${randomUUID()}`, customerMessage: 'DEV SIMULATED SUCCESS' };
      this.logger.warn(`[MPESA][DEV MODE ACTIVE] Simulating STK success for post=${dto.post_id} (no Daraja call)`);
    } else {
      try {
        stkResult = await this.daraja.stkPush({ phone: buyerPhone, amount: totalPaid, postId: dto.post_id });
      } catch (err) {
        await this.transactions.update(transaction.id, { status: 'failed' });
        const detail = err instanceof Error ? err.message : String(err);
        this.logger.error(`[PAY] STK push failed — ${detail}`);
        throw new BadRequestException(detail);
      }
    }

    await this.transactions.update(transaction.id, {
      checkout_request_id: stkResult.checkoutRequestId,
    });

    void this.events.emit({
      type: EVENT_TYPES.PAYMENT_STK_SENT,
      actorUserId: dto.buyer_user_id,
      entityType: 'payment',
      entityId: transaction.id,
      payload: { post_id: dto.post_id, checkout_request_id: stkResult.checkoutRequestId },
    });

    // FREEZE WHERE THE MONEY WILL GO, NOW.
    //
    // This is the moment both parties commit: the client is paying, the
    // provider is selected. Capturing the destination here — rather than
    // re-deriving it at payout — is what makes the payout destination a TERM OF
    // THE DEAL instead of a mutable profile field. A provider who later changes
    // their number is paid to the new one on their NEXT job; money already
    // earned is unaffected, and neither a careless edit nor an account takeover
    // can redirect it.
    //
    // Null is a normal outcome (feature off, or provider has no destination
    // row): the escrow is created without a snapshot and settles through the
    // transitional path, exactly as every escrow does today.
    // The audit event id is generated BEFORE either write, so the snapshot can
    // reference the event and the event can reference the escrow without either
    // pointing at something that does not exist yet.
    const captureEventId = randomUUID();
    const frozen = await this.payoutDestinations.buildSnapshot(
      post.selected_provider_id as string,
      'mpesa',
      captureEventId,
    );
    if (frozen) {
      // emitOrThrow: nothing has moved yet. A capture that cannot be recorded
      // must not happen at all — refusing costs nothing and an unauditable
      // freeze is exactly what this design exists to prevent.
      await this.payoutAudit.emitOrThrow({
        eventId: captureEventId,
        providerUserId: post.selected_provider_id as string,
        eventType: 'payout_snapshot_captured',
        actorType: 'system',
        payoutDestinationId: frozen.id,
        transactionId: transaction.id,
        destinationFingerprint: frozen.snapshot.destination_fingerprint,
        normalizedDestination: frozen.snapshot.normalized_destination,
        channel: frozen.snapshot.channel,
        metadata: {
          post_id: dto.post_id,
          amount,
          verification_method: frozen.snapshot.verification_method,
        },
      });
      this.logger.log(
        `[PAY][DEST] frozen destination=${frozen.id} method=${frozen.snapshot.verification_method} post=${dto.post_id}`,
      );
    }

    // Optimistically create escrow. If this insert fails, the payment.success
    // event handler will upsert it when the STK callback arrives (bug fix).
    const { error: escrowError } = await this.supabase.client
      .from('escrow')
      .insert({
        post_id: dto.post_id,
        transaction_id: transaction.id,
        amount,
        status: 'locked',
        ...(frozen
          ? {
              payout_destination_id: frozen.id,
              payout_destination_snapshot: frozen.snapshot,
            }
          : {}),
      });

    if (escrowError) {
      this.logger.error(
        `[PAY] Escrow insert failed for tx ${transaction.id} — processor will fix on callback: ${escrowError.message}`,
      );
    }

    // DEV MODE: feed a simulated SUCCESS callback into the REAL handler so the
    // transaction → paid, payment.success event and payment_secured notification
    // all run exactly as production would on the Daraja STK callback.
    if (this.devForceSuccess) {
      await this.handleStkCallback(this.buildSimulatedStkCallback(stkResult.checkoutRequestId, amount));
    }

    return {
      transaction_id: transaction.id,
      checkout_request_id: stkResult.checkoutRequestId,
      amount,
      fee,
      total_paid: totalPaid,
      message: stkResult.customerMessage,
    };
  }

  // ── Sandbox smoke-test ─────────────────────────────────────────────────────

  /**
   * Push an STK prompt to an arbitrary number, for wiring checks.
   *
   * BLOCKED IN PRODUCTION, matching `forceSuccessForDev` and
   * `resetPaymentLockForDev` above. This endpoint takes the destination phone
   * from the request body, so in production it is an arbitrary-number PIN-prompt
   * generator: a way to harass any Safaricom subscriber and to burn Daraja quota
   * at the same time. The Phase 1 audit flagged it and recommended exactly this
   * gate; the controller additionally now requires an authenticated caller, but
   * authentication alone would only have narrowed the attacker set to "anyone
   * with an account", which for a free consumer app is not a meaningful bound.
   */
  async testStk(phone: string, amount = 1): Promise<Record<string, unknown>> {
    const env = process.env.MPESA_ENV ?? 'sandbox';
    if (env === 'production') {
      this.logger.error('[TEST-STK] called in production — BLOCKED');
      throw new BadRequestException('The STK smoke test is not available in production.');
    }

    const normalized = normalizePhone(phone);
    this.logger.log(`[TEST-STK] phone raw="${phone}" normalized="${normalized ?? 'invalid'}" amount=${amount}`);
    if (!normalized) {
      return { ok: false, phone, error: 'Invalid phone number. Use 254XXXXXXXXX or 07XXXXXXXX.' };
    }
    try {
      const result = await this.daraja.stkPush({ phone: normalized, amount, postId: 'test-smoke-test' });
      return { ok: true, phone: normalized, amount, ...result };
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      return { ok: false, phone: normalized, amount, error: detail };
    }
  }

  // ── STK push callback (called by Daraja) ───────────────────────────────────

  /**
   * Registers a fallback consumer for STK callbacks that match no escrow
   * transaction (e.g. promotion purchases). Called by feature services in
   * onModuleInit — keeps this module free of upward dependencies.
   */
  registerStkCallbackFallback(fallback: StkCallbackFallback): void {
    this.stkCallbackFallbacks.push(fallback);
    this.logger.log(`[CALLBACK] STK fallback consumer registered: ${fallback.name}`);
  }

  /** Extract receipt + amount from Daraja's CallbackMetadata items. */
  private parseStkMetadata(callback: Record<string, unknown>): {
    receipt: string | null;
    amount: number | null;
  } {
    const items =
      ((callback.CallbackMetadata as Record<string, unknown>)?.Item as Array<{
        Name: string;
        Value: unknown;
      }>) ?? [];
    const receipt = items.find((i) => i.Name === 'MpesaReceiptNumber')?.Value as string | undefined;
    const amount = items.find((i) => i.Name === 'Amount')?.Value as number | undefined;
    return { receipt: receipt ?? null, amount: amount ?? null };
  }

  async handleStkCallback(body: Record<string, unknown>): Promise<void> {
    this.logger.log(`[CALLBACK] STK raw payload: ${JSON.stringify(body)}`);

    const callback = (body?.Body as Record<string, unknown>)
      ?.stkCallback as Record<string, unknown> | undefined;

    if (!callback) {
      this.logger.warn('[CALLBACK] Malformed STK payload — missing Body.stkCallback');
      return;
    }

    const checkoutRequestId = callback.CheckoutRequestID as string;
    const resultCode = callback.ResultCode as number;
    const resultDesc = callback.ResultDesc as string;

    const transaction = await this.transactions.findByCheckoutRequestId(checkoutRequestId);
    if (!transaction) {
      // Not an escrow payment — offer it to fallback consumers (promotions, …)
      // before declaring it unmatched. A consumer that claims it ends routing.
      const parsed = {
        checkoutRequestId,
        resultCode,
        resultDesc,
        ...this.parseStkMetadata(callback),
      };
      for (const fallback of this.stkCallbackFallbacks) {
        if (await fallback.handle(parsed)) {
          this.logger.log(
            `[CALLBACK] STK ${checkoutRequestId} handled by fallback consumer '${fallback.name}'`,
          );
          return;
        }
      }
      this.logger.error(`STK callback: no transaction for CheckoutRequestID ${checkoutRequestId}`);
      return;
    }

    if (transaction.status !== 'pending') {
      this.logger.log(
        `STK callback: transaction ${transaction.id} already in status '${transaction.status}', skipping`,
      );
      return;
    }

    if (resultCode === 0) {
      const { receipt } = this.parseStkMetadata(callback);

      await this.transactions.update(transaction.id, {
        status: 'paid',
        mpesa_receipt: receipt ?? null,
      });

      this.logger.log(`Payment confirmed: transaction ${transaction.id}, receipt ${receipt ?? 'n/a'}`);

      // payment.success: EventProcessorService will upsert escrow (fixes orphan bug).
      // Processed=false — the 60 s retry loop or immediate dispatch will handle it.
      void this.events.emit({
        type: EVENT_TYPES.PAYMENT_SUCCESS,
        entityType: 'payment',
        entityId: transaction.id,
        payload: {
          transaction_id: transaction.id,
          post_id: transaction.post_id as string,
          amount: transaction.amount as number,
        },
      });

      // Notify provider inline (fast path — no retry needed for this push).
      await this.notifyPaymentSecured(transaction.post_id as string, transaction.id);
    } else {
      await this.transactions.update(transaction.id, {
        status: 'failed',
        failure_reason: resultDesc ?? 'Payment failed.',
      });

      void this.events.emit({
        type: EVENT_TYPES.PAYMENT_FAILED,
        entityType: 'payment',
        entityId: transaction.id,
        payload: { transaction_id: transaction.id, result_code: resultCode, result_desc: resultDesc },
      });

      this.logger.warn(
        `Payment failed: transaction ${transaction.id} — code=${resultCode} desc="${resultDesc}"`,
      );
    }
  }

  // ── Release payout (B2C) ───────────────────────────────────────────────────

  async releasePayout(dto: ReleasePayoutDto, opts: { allowFromDisputed?: boolean } = {}) {
    this.logger.log(`[PAYOUT][START] postId=${dto.post_id}${opts.allowFromDisputed ? ' (dispute-release)' : ''}`);

    const { data: post, error: postError } = await this.supabase.client
      .from('posts')
      .select('id, title, selected_provider_id')
      .eq('id', dto.post_id)
      .single();

    if (postError || !post) throw new NotFoundException(`Post ${dto.post_id} not found.`);
    if (!post.selected_provider_id) throw new BadRequestException('No provider has been selected for this post.');

    // Normal (approve) flow releases a 'paid' transaction. Arbitration releases a
    // transaction that was frozen to 'disputed' at dispute creation, so the caller
    // must opt in with allowFromDisputed. We select only from releasable source
    // states so an already 'released'/'payout_pending' tx is treated as a conflict
    // below rather than being paid out twice.
    const allowedSourceStatuses = opts.allowFromDisputed ? ['paid', 'disputed'] : ['paid'];
    const { data: transaction } = await this.supabase.client
      .from('transactions')
      .select('*')
      .eq('post_id', dto.post_id)
      .in('status', allowedSourceStatuses)
      .order('created_at', { ascending: false })
      .limit(1)
      .single();

    if (!transaction) {
      // Disambiguate "already paid out" from "nothing to pay" for a clear error.
      const { data: latest } = await this.supabase.client
        .from('transactions')
        .select('status')
        .eq('post_id', dto.post_id)
        .order('created_at', { ascending: false })
        .limit(1)
        .single();
      if (latest?.status === 'released') throw new ConflictException('Payout already released.');
      if (latest?.status === 'payout_pending') throw new ConflictException('Payout is already in progress.');
      throw new NotFoundException('No releasable payment found for this post.');
    }

    this.logger.log(
      `[PAYOUT][START] postId=${dto.post_id} txId=${transaction.id as string} amount=${transaction.amount as number}`,
    );

    // ── WHERE THE MONEY GOES ────────────────────────────────────────────────
    //
    // Resolved from the destination FROZEN onto this escrow when it was
    // created. It is not re-derived from the provider's profile, because a
    // profile is mutable and this decision was made when both parties agreed.
    //
    // `source` is logged on every payout deliberately: it is the measurement
    // that gates Phase 4. While it reads `current_destination`, escrows created
    // before the snapshot existed are still settling, and the transitional path
    // cannot be removed. When it is `escrow_snapshot` for every payout, it can.
    const { data: escrowRow } = await this.supabase.client
      .from('escrow')
      .select('payout_destination_snapshot')
      .eq('transaction_id', transaction.id as string)
      .maybeSingle();

    const resolved = await this.payoutDestinations.resolveForPayout({
      providerUserId: post.selected_provider_id as string,
      escrowSnapshot: this.payoutDestinations.parseSnapshot(
        escrowRow?.payout_destination_snapshot,
      ),
    });

    let providerPhone: string | null;
    let payoutDestinationId: string | null = null;

    if (resolved.kind === 'paid') {
      providerPhone = normalizePhone(resolved.msisdn);
      payoutDestinationId = resolved.destinationId;
      this.logger.log(
        `[PAYOUT][DEST] postId=${dto.post_id} source=${resolved.source} ` +
          `destination=${resolved.destinationId} verified=${resolved.verified}`,
      );
      // emitOrThrow: the B2C call has not happened yet. A payout that cannot be
      // recorded must not start.
      await this.payoutAudit.emitOrThrow({
        providerUserId: post.selected_provider_id as string,
        eventType: 'payout_initiated',
        actorType: 'system',
        payoutDestinationId: resolved.destinationId,
        transactionId: transaction.id as string,
        normalizedDestination: resolved.msisdn,
        channel: 'mpesa',
        metadata: {
          post_id: dto.post_id,
          amount: transaction.amount as number,
          source: resolved.source,
          strongly_verified: resolved.verified,
          from_disputed: opts.allowFromDisputed ?? false,
        },
      });
    } else if (this.payoutDestinations.isEnabled) {
      // The feature is on and it refused. Refusing is the correct outcome — do
      // not silently fall back to the profile number, which is the entire
      // behaviour this work exists to remove.
      this.logger.error(
        `[PAYOUT][DEST] postId=${dto.post_id} REFUSED reason=${resolved.reason} source=${resolved.source}`,
      );
      // A refusal is a payout decision and belongs in the trail: "why did this
      // provider not get paid on the 3rd?" is a question support will be asked.
      // emit (not emitOrThrow) — the refusal itself must reach the caller even
      // if the audit write also fails.
      await this.payoutAudit.emit({
        providerUserId: post.selected_provider_id as string,
        eventType: 'payout_refused',
        actorType: 'system',
        transactionId: transaction.id as string,
        reason: resolved.reason,
        metadata: { post_id: dto.post_id, source: resolved.source },
      });
      throw new BadRequestException(explainFailure(resolved.reason));
    } else {
      // Feature disabled (migrations not yet applied). Behave exactly as before.
      const { data: providerUser } = await this.supabase.client
        .from('users')
        .select('phone_number')
        .eq('id', post.selected_provider_id)
        .single();

      if (!providerUser) throw new NotFoundException('Provider not found.');
      providerPhone = normalizePhone(providerUser.phone_number);
      this.logger.log(
        `[PAYOUT][DEST] postId=${dto.post_id} source=profile_phone (payout destinations disabled)`,
      );
    }

    if (!providerPhone) {
      throw new BadRequestException('Provider has not added a valid M-Pesa payout number.');
    }

    this.logger.log(
      `[PAYOUT][DARAJA_REQUEST] postId=${dto.post_id} txId=${transaction.id as string} amount=${transaction.amount as number} providerPhone=${providerPhone}`,
    );

    let b2cResult: Awaited<ReturnType<typeof this.daraja.b2cPayout>>;
    if (this.devForceSuccess) {
      // DEV MODE: skip Daraja B2C. The simulated SUCCESS callback fired below runs
      // the real settlement pipeline (tx → released, escrow → released, event +
      // payout-confirmed notification).
      b2cResult = {
        conversationId: `DEV_${randomUUID()}`,
        originatorConversationId: `DEV_${randomUUID()}`,
      } as Awaited<ReturnType<typeof this.daraja.b2cPayout>>;
      this.logger.warn(`[MPESA][DEV MODE ACTIVE] Simulating B2C payout for post=${dto.post_id} (no Daraja call)`);
    } else {
      try {
        b2cResult = await this.daraja.b2cPayout({
          phone: providerPhone,
          amount: transaction.amount as number,
          jobId: dto.post_id,
        });
      } catch (err) {
        const detail = err instanceof Error ? err.message : String(err);
        this.logger.error(
          `[PAYOUT][FAILED] postId=${dto.post_id} txId=${transaction.id as string} — ${detail}`,
        );
        throw err;
      }
    }

    this.logger.log(
      `[PAYOUT][DARAJA_RESPONSE] postId=${dto.post_id} txId=${transaction.id as string} conversationId=${b2cResult.conversationId} originatorConversationId=${b2cResult.originatorConversationId}`,
    );

    // MONEY HAS NOW LEFT. From here on, emission failures are logged and NEVER
    // block: refusing to record a payout that already happened does not un-send
    // it, it only destroys the evidence that it went.
    void this.payoutAudit.emit({
      providerUserId: post.selected_provider_id as string,
      eventType: 'payout_sent_to_processor',
      actorType: 'system',
      payoutDestinationId: payoutDestinationId,
      transactionId: transaction.id as string,
      normalizedDestination: providerPhone,
      channel: 'mpesa',
      metadata: {
        post_id: dto.post_id,
        amount: transaction.amount as number,
        conversation_id: b2cResult.conversationId,
        originator_conversation_id: b2cResult.originatorConversationId,
        simulated: this.devForceSuccess,
      },
    });

    await this.transactions.update(transaction.id as string, {
      status: 'payout_pending',
      conversation_id: b2cResult.conversationId,
      // Persisted so a stranded payout (missing B2C callback) can later be
      // reconciled via Daraja's Transaction Status Query, which correlates by
      // OriginatorConversationID rather than the ConversationID.
      originator_conversation_id: b2cResult.originatorConversationId,
    });

    // Stamp what was ACTUALLY paid. This is the record a reconciliation or a
    // dispute reads years later: it names the destination the money went to,
    // which — via the destination row — names the verification that proved it.
    if (payoutDestinationId) {
      const { error: stampError } = await this.supabase.client
        .from('transactions')
        .update({ payout_destination_id: payoutDestinationId })
        .eq('id', transaction.id as string);
      if (stampError) {
        // Never fail a payout that has already left over an audit column, but
        // say so loudly — a payout whose destination is unrecorded is exactly
        // the gap this design exists to close.
        this.logger.error(
          `[PAYOUT][DEST] destination stamp failed for txId=${transaction.id as string}: ${stampError.message}`,
        );
      }
    }

    const { error: escrowError } = await this.supabase.client
      .from('escrow')
      .update({ status: 'payout_pending', provider_id: post.selected_provider_id as string })
      .eq('transaction_id', transaction.id as string);

    if (escrowError) {
      this.logger.error(
        `[PAYOUT][FAILED] escrow update failed for txId=${transaction.id as string}: ${escrowError.message}`,
      );
    } else {
      this.logger.log(
        `[PAYOUT][SUCCESS] postId=${dto.post_id} txId=${transaction.id as string} status=payout_pending conversationId=${b2cResult.conversationId}`,
      );
    }

    void this.events.emit({
      type: EVENT_TYPES.ESCROW_PAYOUT_PENDING,
      entityType: 'escrow',
      entityId: transaction.id as string,
      payload: { post_id: dto.post_id, transaction_id: transaction.id, conversation_id: b2cResult.conversationId },
    });

    // DEV MODE: feed a simulated SUCCESS callback into the REAL handler so the
    // settlement pipeline (tx → released, escrow → released, escrow_released event
    // + payout-confirmed notification) runs exactly as production.
    if (this.devForceSuccess) {
      await this.handleB2cCallback(this.buildSimulatedB2cCallback(b2cResult.conversationId));
    }

    return { message: 'Payout initiated.', transaction_id: transaction.id };
  }

  // ── B2C settlement engine (single idempotent terminal writer) ──────────────
  //
  // Every path that finalises a payout — the real B2C RESULT callback, the
  // Transaction Status Query result, the admin reconcile flow, and the dev
  // simulation — funnels through settleByTransaction(). It is the ONLY code that
  // moves a payout to a terminal state, so behaviour is identical regardless of
  // which signal arrives, duplicate signals are safe, and split-brain states are
  // self-healing. It settles ONLY on a definitive result — never on elapsed time.

  private static readonly PS = '[PAYOUT_STATE]';

  /**
   * Idempotently apply a DEFINITIVE B2C result to a single transaction + its escrow.
   *
   *   - tx already 'released'      → repair escrow if it lagged (split-brain), else no-op.
   *   - tx 'payout_pending' + ok   → tx+escrow → 'released', emit escrow.released ONCE.
   *   - tx 'payout_pending' + fail → tx → 'paid' (+failure_reason), escrow → 'locked'.
   *   - tx any other status        → no-op (cannot settle a non-pending payout).
   */
  private async settleByTransaction(
    tx: {
      id: string;
      status: string;
      post_id?: unknown;
      amount?: unknown;
      /** Present since migration 107; the destination this payout actually used. */
      payout_destination_id?: unknown;
    },
    result: { resultCode: number; resultDesc: string; source: string },
  ): Promise<{ outcome: 'released' | 'reverted' | 'repaired' | 'noop'; reason: string }> {
    const { resultCode, resultDesc, source } = result;
    const PS = MpesaService.PS;
    const txId = tx.id;

    // ── Already terminal-released → repair a lagging escrow row (invariant #6) ──
    if (tx.status === 'released') {
      const { data: escrow } = await this.supabase.client
        .from('escrow')
        .select('status, released_at')
        .eq('transaction_id', txId)
        .maybeSingle();

      if (escrow && (escrow as { status: string }).status !== 'released') {
        const { error } = await this.supabase.client
          .from('escrow')
          .update({
            status: 'released',
            released_at: (escrow as { released_at: string | null }).released_at ?? new Date().toISOString(),
          })
          .eq('transaction_id', txId)
          .neq('status', 'released');

        if (error) {
          this.logger.error(`${PS} [${source}] split-brain repair FAILED tx=${txId}: ${error.message}`);
          return { outcome: 'noop', reason: 'escrow_repair_failed' };
        }
        this.logger.warn(
          `${PS} [${source}] split-brain repair: tx=${txId} already released, escrow ${(escrow as { status: string }).status}→released`,
        );
        // Do NOT re-emit escrow.released — the payout notification already fired on
        // the original release. Repair only re-syncs state.
        return { outcome: 'repaired', reason: 'escrow_synced_to_released' };
      }

      this.logger.log(`${PS} [${source}] tx=${txId} already fully released — idempotent no-op`);
      return { outcome: 'noop', reason: 'already_released' };
    }

    // ── Only a payout_pending tx can be settled from a result ──
    if (tx.status !== 'payout_pending') {
      this.logger.log(`${PS} [${source}] tx=${txId} status='${tx.status}' not settleable — skipping`);
      return { outcome: 'noop', reason: `not_pending_${tx.status}` };
    }

    // ── Confirmed SUCCESS → terminal release ──
    if (resultCode === 0) {
      await this.transactions.update(txId, { status: 'released' });

      const { error } = await this.supabase.client
        .from('escrow')
        .update({ status: 'released', released_at: new Date().toISOString() })
        .eq('transaction_id', txId)
        .neq('status', 'released');

      if (error) {
        this.logger.error(
          `${PS} [${source}] CRITICAL tx=${txId} released but escrow update failed: ${error.message}`,
        );
      }
      this.logger.log(`${PS} [${source}] tx=${txId} SETTLED → released`);

      const { data: post } = await this.supabase.client
        .from('posts')
        .select('title, author_user_id, selected_provider_id')
        .eq('id', tx.post_id as string)
        .single();

      // EXACTLY ONCE per payout: we only reach here from `payout_pending`, and
      // the transition to `released` happened above — so a duplicate callback,
      // a replayed callback and a status-query racing the callback all land in
      // the `already_released` no-op branch and never get here twice.
      void this.payoutAudit.emit({
        providerUserId: (post?.selected_provider_id as string) ?? 'unknown',
        eventType: 'payout_completed',
        actorType: 'processor',
        transactionId: txId,
        payoutDestinationId: (tx.payout_destination_id as string | null) ?? null,
        metadata: {
          post_id: tx.post_id as string,
          amount: tx.amount as number,
          source,
          result_code: resultCode,
        },
      });

      // escrow.released → EventProcessorService notifies both parties. Because we
      // only reach here from payout_pending, this fires exactly once per payout.
      void this.events.emit({
        type: EVENT_TYPES.ESCROW_RELEASED,
        entityType: 'escrow',
        entityId: txId,
        payload: {
          transaction_id: txId,
          post_id:     tx.post_id as string,
          post_title:  post?.title as string | undefined,
          provider_id: post?.selected_provider_id as string | undefined,
          buyer_id:    post?.author_user_id as string | undefined,
        },
      });
      return { outcome: 'released', reason: 'b2c_success' };
    }

    // ── Confirmed FAILURE → revert to a recoverable state + record the reason ──
    await this.transactions.update(txId, {
      status: 'paid',
      conversation_id: null,
      originator_conversation_id: null,
      failure_reason: resultDesc ?? 'B2C payout failed.',
    });

    const { error } = await this.supabase.client
      .from('escrow')
      .update({ status: 'locked', provider_id: null })
      .eq('transaction_id', txId);

    if (error) {
      this.logger.error(`${PS} [${source}] escrow revert failed tx=${txId}: ${error.message}`);
    }
    this.logger.warn(
      `${PS} [${source}] tx=${txId} B2C FAILED (code=${resultCode} "${resultDesc}") → reverted to paid/locked`,
    );

    // Same once-only guarantee as the success branch: reachable only from
    // `payout_pending`, and that status has already been changed above.
    // `.single()` to match the success branch above, which queries the same row
    // the same way. Supabase returns `{data: null, error}` rather than throwing
    // when there is no match, so a missing post degrades to actor 'unknown'
    // rather than losing the event.
    const { data: failedPost } = await this.supabase.client
      .from('posts')
      .select('selected_provider_id')
      .eq('id', tx.post_id as string)
      .single();

    void this.payoutAudit.emit({
      providerUserId: (failedPost?.selected_provider_id as string) ?? 'unknown',
      eventType: 'payout_failed',
      actorType: 'processor',
      transactionId: txId,
      payoutDestinationId: (tx.payout_destination_id as string | null) ?? null,
      reason: resultDesc ?? 'B2C payout failed.',
      metadata: { post_id: tx.post_id as string, source, result_code: resultCode },
    });

    void this.events.emit({
      type: EVENT_TYPES.ESCROW_PAYOUT_PENDING,
      entityType: 'escrow',
      entityId: txId,
      payload: { reverted: true, result_code: resultCode, result_desc: resultDesc },
    });
    return { outcome: 'reverted', reason: 'b2c_failure' };
  }

  /** Resolve a B2C result to its transaction by ConversationID, then settle. */
  private async settleByConversation(input: {
    conversationId: string;
    resultCode: number;
    resultDesc: string;
    source: string;
  }): Promise<{ outcome: string; reason: string }> {
    const tx = await this.transactions.findByConversationId(input.conversationId);
    if (!tx) {
      this.logger.error(
        `${MpesaService.PS} [${input.source}] no transaction for ConversationID ${input.conversationId}`,
      );
      return { outcome: 'noop', reason: 'no_tx' };
    }
    return this.settleByTransaction(tx, {
      resultCode: input.resultCode,
      resultDesc: input.resultDesc,
      source: input.source,
    });
  }

  // ── B2C callback (called by Daraja) ───────────────────────────────────────

  async handleB2cCallback(body: Record<string, unknown>): Promise<void> {
    this.logger.log(`[CALLBACK] B2C raw payload: ${JSON.stringify(body)}`);

    const result = body?.Result as Record<string, unknown> | undefined;
    if (!result) {
      this.logger.warn('[CALLBACK] Malformed B2C payload — missing Result');
      return;
    }

    const resultCode = Number(result.ResultCode);
    const resultDesc = result.ResultDesc as string;
    const conversationId = result.ConversationID as string;

    this.logger.log(
      `[PAYOUT][CALLBACK_RECEIVED] conversationId=${conversationId} resultCode=${resultCode} resultDesc="${resultDesc}"`,
    );

    await this.settleByConversation({ conversationId, resultCode, resultDesc, source: 'b2c-callback' });
  }

  // ── Transaction Status Query RESULT (async reconcile answer from Daraja) ───
  //
  // Daraja POSTs the definitive status of a queried B2C payout here after an
  // admin reconcile dispatched a Transaction Status Query. We settle ONLY when the
  // original transaction's real status is a confirmed terminal value — never on
  // ambiguity or timeout. Correlation: the query's `Occasion` (= our tx's
  // conversation_id) is echoed back in ReferenceData; OriginatorConversationID is
  // the fallback key.

  async handleB2cStatusResult(body: Record<string, unknown>): Promise<void> {
    const PS = MpesaService.PS;
    this.logger.log(`${PS} [status-result] raw payload: ${JSON.stringify(body)}`);

    const result = body?.Result as Record<string, unknown> | undefined;
    if (!result) {
      this.logger.warn(`${PS} [status-result] malformed — missing Result`);
      return;
    }

    const queryResultCode = Number(result.ResultCode); // 0 = the QUERY itself succeeded
    const originator = result.OriginatorConversationID as string | undefined;

    const refItems = ((result.ReferenceData as Record<string, unknown>)?.ReferenceItem ?? []) as
      | Array<{ Key: string; Value: unknown }>
      | { Key: string; Value: unknown };
    const refArr = Array.isArray(refItems) ? refItems : [refItems];
    const occasion = refArr.find((i) => i?.Key === 'Occasion')?.Value as string | undefined;

    const params = ((result.ResultParameters as Record<string, unknown>)?.ResultParameter ?? []) as
      | Array<{ Key: string; Value: unknown }>
      | { Key: string; Value: unknown };
    const pArr = Array.isArray(params) ? params : [params];
    const txnStatus = pArr.find((p) => p?.Key === 'TransactionStatus')?.Value as string | undefined;

    // Correlate the answer back to our transaction.
    let tx = occasion ? await this.transactions.findByConversationId(occasion) : null;
    if (!tx && originator) tx = await this.transactions.findByOriginatorConversationId(originator);
    if (!tx) {
      this.logger.error(
        `${PS} [status-result] could not correlate to a transaction (occasion=${occasion ?? 'n/a'} originator=${originator ?? 'n/a'})`,
      );
      return;
    }

    if (queryResultCode !== 0) {
      this.logger.warn(
        `${PS} [status-result] query failed (code=${queryResultCode}) for tx=${tx.id} — leaving payout pending`,
      );
      return;
    }

    const status = (txnStatus ?? '').toLowerCase();
    if (status === 'completed') {
      await this.settleByTransaction(tx, {
        resultCode: 0,
        resultDesc: `status-query: ${txnStatus}`,
        source: 'status-result',
      });
    } else if (status === 'failed' || status === 'cancelled' || status === 'canceled') {
      await this.settleByTransaction(tx, {
        resultCode: 1,
        resultDesc: `status-query: ${txnStatus}`,
        source: 'status-result',
      });
    } else {
      // Unknown / still-processing status → do NOT move money. Leave pending.
      this.logger.warn(
        `${PS} [status-result] tx=${tx.id} inconclusive status='${txnStatus ?? 'none'}' — leaving payout pending`,
      );
    }
  }

  // ── Admin reconcile (recover a stranded payout_pending transaction) ────────
  //
  // Safe recovery for invariant #5 (callback that never arrives) and #6 (split
  // brain). It NEVER releases money merely because a payout has been pending a
  // long time — it settles only on a confirmed result:
  //   • dev  → a simulated CONFIRMED success runs the real settlement pipeline.
  //   • prod → dispatch Daraja's Transaction Status Query; settlement happens only
  //            when handleB2cStatusResult confirms completion.

  async reconcilePayout(
    postId: string,
    actor = 'system',
  ): Promise<{ status: string; action: string; message: string; transaction_id?: string }> {
    const PS = MpesaService.PS;
    this.logger.warn(`${PS} [reconcile] ▶ post=${postId} by=${actor}`);

    const tx = await this.transactions.findLatestByPostId(postId);
    if (!tx) throw new NotFoundException(`No transaction found for post ${postId}.`);

    // Already released → repair a lagging escrow if needed (split-brain).
    if (tx.status === 'released') {
      const r = await this.settleByTransaction(tx, {
        resultCode: 0,
        resultDesc: 'reconcile',
        source: 'reconcile',
      });
      return {
        status: 'released',
        action: r.outcome,
        transaction_id: tx.id,
        message:
          r.outcome === 'repaired'
            ? 'Transaction was released; escrow was stale and has been repaired to released.'
            : 'Transaction and escrow are already released — nothing to do.',
      };
    }

    if (tx.status !== 'payout_pending') {
      return {
        status: tx.status,
        action: 'noop',
        transaction_id: tx.id,
        message: `Transaction is '${tx.status}', not awaiting a payout — nothing to reconcile.`,
      };
    }

    if (this.devForceSuccess) {
      this.logger.warn(
        `${PS} [reconcile][DEV MODE] simulating CONFIRMED B2C success for tx=${tx.id} (no Daraja call)`,
      );
      const r = await this.settleByTransaction(tx, {
        resultCode: 0,
        resultDesc: 'DEV SIMULATED RECONCILE SUCCESS',
        source: 'reconcile-dev',
      });
      return {
        status: r.outcome === 'released' ? 'released' : tx.status,
        action: r.outcome,
        transaction_id: tx.id,
        message: 'DEV reconcile: simulated confirmed success and settled the payout.',
      };
    }

    // PROD: ask Daraja what actually happened. We do NOT settle here.
    if (!tx.conversation_id && !tx.originator_conversation_id) {
      return {
        status: tx.status,
        action: 'noop',
        transaction_id: tx.id,
        message:
          'Transaction has neither conversation_id nor originator_conversation_id — cannot query Daraja. Manual investigation required.',
      };
    }

    await this.daraja.transactionStatusQuery({
      originatorConversationId: tx.originator_conversation_id ?? undefined,
      occasion: tx.conversation_id ?? undefined,
      remarks: `Help24 reconcile post ${postId}`,
    });

    this.logger.warn(
      `${PS} [reconcile] dispatched Transaction Status Query for tx=${tx.id} conv=${tx.conversation_id ?? 'n/a'} — awaiting result callback`,
    );
    return {
      status: tx.status,
      action: 'query_dispatched',
      transaction_id: tx.id,
      message:
        'Daraja Transaction Status Query dispatched. The payout will settle ONLY if Daraja confirms the transaction completed; the async result arrives at /mpesa/b2c-status-result.',
    };
  }

  // ── DEV ONLY: force pending → paid ────────────────────────────────────────

  async forceSuccessForDev(postId: string): Promise<{ ok: boolean; message: string }> {
    const env = process.env.MPESA_ENV ?? 'sandbox';
    if (env === 'production') {
      this.logger.error('[DEV] force-success called in production — BLOCKED');
      throw new BadRequestException('Force-success is not available in production.');
    }

    this.logger.warn(`[DEV] ⚠️  force-success — post=${postId} env=${env}`);

    const { data: transaction } = await this.supabase.client
      .from('transactions')
      .select('id, status, amount, post_id')
      .eq('post_id', postId)
      .eq('status', 'pending')
      .maybeSingle();

    if (!transaction) throw new NotFoundException('No pending transaction found for this post.');

    const fakeReceipt = `DEV${Date.now()}`;
    await this.transactions.update(transaction.id as string, { status: 'paid', mpesa_receipt: fakeReceipt });
    await this.supabase.client.from('escrow').update({ status: 'locked' }).eq('transaction_id', transaction.id as string);

    void this.events.emit({
      type: EVENT_TYPES.PAYMENT_SUCCESS,
      entityType: 'payment',
      entityId: transaction.id as string,
      payload: { transaction_id: transaction.id, post_id: postId, amount: transaction.amount },
    });

    await this.notifyPaymentSecured(postId, transaction.id as string);

    return { ok: true, message: `[DEV] Forced success for tx ${transaction.id as string}. Fake receipt: ${fakeReceipt}` };
  }

  // ── DEV ONLY: clear stuck pending-transaction lock ────────────────────────

  async resetPaymentLockForDev(postId: string): Promise<{ ok: boolean; cleared: number }> {
    const env = process.env.MPESA_ENV ?? 'sandbox';
    if (env === 'production') {
      this.logger.error('[DEV] reset-payment-lock called in production — BLOCKED');
      throw new BadRequestException('reset-payment-lock is not available in production.');
    }

    this.logger.warn(`[DEV] reset-payment-lock — post=${postId} env=${env}`);

    const { data: txs } = await this.supabase.client
      .from('transactions')
      .update({ status: 'failed', failure_reason: 'dev_lock_reset', checkout_request_id: null })
      .eq('post_id', postId)
      .eq('status', 'pending')
      .select('id');

    const count = txs?.length ?? 0;
    this.logger.warn(`[DEV] reset-payment-lock: cleared ${count} pending tx(s) for post=${postId}`);
    return { ok: true, cleared: count };
  }

  // ── Payment status (polled by Flutter) ─────────────────────────────────────

  async getStatus(postId: string) {
    const { data, error } = await this.supabase.client
      .from('transactions')
      .select('id, post_id, amount, fee, total_paid, status, mpesa_receipt, failure_reason, created_at, escrow(status, provider_id, released_at)')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .single();

    if (error || !data) throw new NotFoundException(`No transaction found for post ${postId}.`);
    return data;
  }

  // ── Notification helper ────────────────────────────────────────────────────

  private async notifyPaymentSecured(postId: string, transactionId: string): Promise<void> {
    try {
      const { data: post } = await this.supabase.client
        .from('posts')
        .select('selected_provider_id, title')
        .eq('id', postId)
        .single();

      if (!post?.selected_provider_id) return;

      await this.notifications.send({
        userId: post.selected_provider_id as string,
        type: 'payment_secured',
        title: 'Payment Secured!',
        body: `Payment secured for "${post.title as string}". Complete the job to receive your payout.`,
        data: { post_id: postId, transaction_id: transactionId },
      });
    } catch (err) {
      this.logger.error(`[NOTIF] Failed to notify provider for post ${postId}: ${err}`);
    }
  }
}
