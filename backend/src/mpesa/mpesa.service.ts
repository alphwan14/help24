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

const PHONE_RE = /^254\d{9}$/;

/**
 * Normalizes a raw Kenyan phone number to the canonical `254XXXXXXXXX` form.
 */
function normalizePhone(raw: string | null | undefined): string | null {
  if (!raw) return null;
  let phone = raw.replace(/[\s\-\(\)\+]/g, '');
  if (/^0\d{9}$/.test(phone)) phone = '254' + phone.slice(1);
  else if (/^7\d{8}$/.test(phone)) phone = '254' + phone;
  return PHONE_RE.test(phone) ? phone : null;
}

@Injectable()
export class MpesaService {
  private readonly logger = new Logger(MpesaService.name);

  constructor(
    private readonly daraja: DarajaService,
    private readonly transactions: TransactionsService,
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly events: EventsService,
  ) {}

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

    let stkResult;
    try {
      stkResult = await this.daraja.stkPush({ phone: buyerPhone, amount: totalPaid, postId: dto.post_id });
    } catch (err) {
      await this.transactions.update(transaction.id, { status: 'failed' });
      const detail = err instanceof Error ? err.message : String(err);
      this.logger.error(`[PAY] STK push failed — ${detail}`);
      throw new BadRequestException(detail);
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

    // Optimistically create escrow. If this insert fails, the payment.success
    // event handler will upsert it when the STK callback arrives (bug fix).
    const { error: escrowError } = await this.supabase.client
      .from('escrow')
      .insert({ post_id: dto.post_id, transaction_id: transaction.id, amount, status: 'locked' });

    if (escrowError) {
      this.logger.error(
        `[PAY] Escrow insert failed for tx ${transaction.id} — processor will fix on callback: ${escrowError.message}`,
      );
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

  async testStk(phone: string, amount = 1): Promise<Record<string, unknown>> {
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
      const items = (
        (callback.CallbackMetadata as Record<string, unknown>)?.Item as Array<{ Name: string; Value: unknown }>
      ) ?? [];
      const receipt = items.find((i) => i.Name === 'MpesaReceiptNumber')?.Value as string | undefined;

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

    const { data: providerUser } = await this.supabase.client
      .from('users')
      .select('phone_number')
      .eq('id', post.selected_provider_id)
      .single();

    if (!providerUser) throw new NotFoundException('Provider not found.');

    const providerPhone = normalizePhone(providerUser.phone_number);
    this.logger.log(
      `[PAYOUT][START] providerPhone raw="${providerUser.phone_number ?? ''}" normalized="${providerPhone ?? 'null'}"`,
    );
    if (!providerPhone) {
      throw new BadRequestException('Provider has not added a valid M-Pesa payout number.');
    }

    this.logger.log(
      `[PAYOUT][DARAJA_REQUEST] postId=${dto.post_id} txId=${transaction.id as string} amount=${transaction.amount as number} providerPhone=${providerPhone}`,
    );

    let b2cResult: Awaited<ReturnType<typeof this.daraja.b2cPayout>>;
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

    this.logger.log(
      `[PAYOUT][DARAJA_RESPONSE] postId=${dto.post_id} txId=${transaction.id as string} conversationId=${b2cResult.conversationId} originatorConversationId=${b2cResult.originatorConversationId}`,
    );

    await this.transactions.update(transaction.id as string, {
      status: 'payout_pending',
      conversation_id: b2cResult.conversationId,
    });

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

    return { message: 'Payout initiated.', transaction_id: transaction.id };
  }

  // ── B2C callback (called by Daraja) ───────────────────────────────────────

  async handleB2cCallback(body: Record<string, unknown>): Promise<void> {
    this.logger.log(`[CALLBACK] B2C raw payload: ${JSON.stringify(body)}`);

    const result = body?.Result as Record<string, unknown> | undefined;
    if (!result) {
      this.logger.warn('[CALLBACK] Malformed B2C payload — missing Result');
      return;
    }

    const resultCode = result.ResultCode as number;
    const resultDesc = result.ResultDesc as string;
    const conversationId = result.ConversationID as string;

    this.logger.log(
      `[PAYOUT][CALLBACK_RECEIVED] conversationId=${conversationId} resultCode=${resultCode} resultDesc="${resultDesc}"`,
    );

    const transaction = await this.transactions.findByConversationId(conversationId);
    if (!transaction) {
      this.logger.error(`B2C callback: no transaction for ConversationID ${conversationId}`);
      return;
    }

    if (transaction.status !== 'payout_pending') {
      this.logger.log(
        `B2C callback: transaction ${transaction.id} not in payout_pending (status: ${transaction.status}), skipping`,
      );
      return;
    }

    if (resultCode === 0) {
      await this.transactions.update(transaction.id, { status: 'released' });

      const { error } = await this.supabase.client
        .from('escrow')
        .update({ status: 'released', released_at: new Date().toISOString() })
        .eq('transaction_id', transaction.id);

      if (error) {
        this.logger.error(
          `[CRITICAL] B2C succeeded but failed to update escrow for tx ${transaction.id}: ${error.message}`,
        );
      }

      this.logger.log(`[PAYOUT][SUCCESS] conversationId=${conversationId} txId=${transaction.id} status=released`);

      // Fetch post data for the escrow.released event payload.
      const { data: post } = await this.supabase.client
        .from('posts')
        .select('title, author_user_id, selected_provider_id')
        .eq('id', transaction.post_id as string)
        .single();

      // escrow.released → EventProcessorService sends payout confirmation to both parties.
      // This notification did NOT exist before — provider and buyer now hear when money lands.
      void this.events.emit({
        type: EVENT_TYPES.ESCROW_RELEASED,
        entityType: 'escrow',
        entityId: transaction.id,
        payload: {
          transaction_id: transaction.id,
          post_id:     transaction.post_id as string,
          post_title:  post?.title as string | undefined,
          provider_id: post?.selected_provider_id as string | undefined,
          buyer_id:    post?.author_user_id as string | undefined,
        },
      });
    } else {
      await this.transactions.update(transaction.id, { status: 'paid', conversation_id: null });

      const { error } = await this.supabase.client
        .from('escrow')
        .update({ status: 'locked', provider_id: null })
        .eq('transaction_id', transaction.id);

      if (error) {
        this.logger.error(`Failed to revert escrow after B2C failure for tx ${transaction.id}: ${error.message}`);
      }

      void this.events.emit({
        type: EVENT_TYPES.ESCROW_PAYOUT_PENDING,
        entityType: 'escrow',
        entityId: transaction.id,
        payload: { reverted: true, result_code: resultCode, result_desc: resultDesc },
      });

      this.logger.warn(`[PAYOUT][FAILED] conversationId=${conversationId} txId=${transaction.id} resultCode=${resultCode} resultDesc="${resultDesc}" — escrow reverted to locked`);
    }
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
