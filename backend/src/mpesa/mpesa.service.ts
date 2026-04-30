import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import axios from 'axios';
import { SupabaseService } from '../supabase/supabase.service';
import { TransactionsService } from '../transactions/transactions.service';
import { DarajaService } from './daraja.service';
import { calculateFee, calculateTotal } from './fee';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ReleasePayoutDto } from './dto/release-payout.dto';

const PHONE_RE = /^254\d{9}$/;

/**
 * Normalizes a raw Kenyan phone number to the canonical `254XXXXXXXXX` form.
 * Strips spaces, dashes, and leading `+`.
 * Converts `07XX...` → `254XX...` and `7XX...` → `254XX...`.
 * Returns null if the result is still not a valid 12-digit 254XXXXXXXXX.
 */
function normalizePhone(raw: string | null | undefined): string | null {
  if (!raw) return null;
  let phone = raw.replace(/[\s\-\(\)\+]/g, '');
  if (/^0\d{9}$/.test(phone)) phone = '254' + phone.slice(1);      // 07XX… → 254XX…
  else if (/^7\d{8}$/.test(phone)) phone = '254' + phone;           // 7XX… → 2547XX…
  return PHONE_RE.test(phone) ? phone : null;
}

@Injectable()
export class MpesaService {
  private readonly logger = new Logger(MpesaService.name);

  constructor(
    private readonly daraja: DarajaService,
    private readonly transactions: TransactionsService,
    private readonly supabase: SupabaseService,
  ) {}

  // ── Initiate STK push ──────────────────────────────────────────────────────

  async initiatePayment(dto: InitiatePaymentDto) {
    this.logger.log(`[PAY] ▶ initiate — post=${dto.post_id} buyer=${dto.buyer_user_id}`);

    // All sensitive values come from DB — never trusted from the client.
    const { data: post, error: postError } = await this.supabase.client
      .from('posts')
      .select('id, price, selected_provider_id')
      .eq('id', dto.post_id)
      .single();

    if (postError || !post) {
      this.logger.error(`[PAY] Post not found — ${postError?.message ?? 'null'}`);
      throw new NotFoundException(`Post ${dto.post_id} not found.`);
    }

    this.logger.log(
      `[PAY] Post fetched — price=${post.price} selected_provider_id=${post.selected_provider_id ?? 'null'}`,
    );

    if (!post.selected_provider_id) {
      throw new BadRequestException(
        'No provider has been selected for this service yet.',
      );
    }

    const amount = Math.round(Number(post.price));
    this.logger.log(`[PAY] Amount = KES ${amount}`);
    if (amount < 100) {
      throw new BadRequestException(
        'Service price is below the minimum payment threshold (KES 100).',
      );
    }

    // Block duplicate or in-progress payments.
    const { data: existingTx } = await this.supabase.client
      .from('transactions')
      .select('id, status')
      .eq('post_id', dto.post_id)
      .in('status', ['pending', 'paid'])
      .maybeSingle();

    if (existingTx) {
      this.logger.warn(
        `[PAY] Duplicate blocked — existing tx ${existingTx.id} status=${existingTx.status}`,
      );
      throw new ConflictException(
        existingTx.status === 'paid'
          ? 'Payment has already been made for this service.'
          : 'A payment is already in progress for this service.',
      );
    }

    // Buyer phone — fetched from DB, never from client.
    const { data: buyerUser } = await this.supabase.client
      .from('users')
      .select('phone_number')
      .eq('id', dto.buyer_user_id)
      .maybeSingle();

    const buyerPhone = normalizePhone(buyerUser?.phone_number);
    this.logger.log(
      `[PAY] Buyer phone raw="${buyerUser?.phone_number ?? ''}" normalized="${buyerPhone ?? 'null'}"`,
    );
    if (!buyerPhone) {
      throw new BadRequestException(
        'Please add your M-Pesa number to your profile to make payments.',
      );
    }

    // Provider phone — fetched from DB via selected_provider_id.
    const { data: providerUser } = await this.supabase.client
      .from('users')
      .select('phone_number')
      .eq('id', post.selected_provider_id)
      .maybeSingle();

    const providerPhone = normalizePhone(providerUser?.phone_number);
    this.logger.log(
      `[PAY] Provider phone raw="${providerUser?.phone_number ?? ''}" normalized="${providerPhone ?? 'null'}"`,
    );
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

    let stkResult;
    try {
      stkResult = await this.daraja.stkPush({
        phone: buyerPhone,
        amount: totalPaid,
        postId: dto.post_id,
      });
    } catch (err) {
      await this.transactions.update(transaction.id, { status: 'failed' });
      // Convert to 400 so frontend receives the real Daraja error message.
      const detail = err instanceof Error ? err.message : String(err);
      this.logger.error(`[PAY] STK push failed — ${detail}`);
      throw new BadRequestException(detail);
    }

    await this.transactions.update(transaction.id, {
      checkout_request_id: stkResult.checkoutRequestId,
    });

    const { error: escrowError } = await this.supabase.client
      .from('escrow')
      .insert({
        post_id: dto.post_id,
        transaction_id: transaction.id,
        amount,
        status: 'locked',
      });

    if (escrowError) {
      this.logger.error(
        `[CRITICAL] Failed to create escrow for transaction ${transaction.id}: ${escrowError.message}`,
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

  // ── Sandbox smoke-test (non-production only) ──────────────────────────────

  async testStk(phone: string): Promise<Record<string, unknown>> {
    const normalized = normalizePhone(phone);
    this.logger.log(`[TEST-STK] phone raw="${phone}" normalized="${normalized ?? 'invalid'}" amount=1`);
    if (!normalized) {
      return { ok: false, phone, error: 'Invalid phone number. Use 254XXXXXXXXX or 07XXXXXXXX.' };
    }
    phone = normalized;
    const amount = 1;
    this.logger.log(`[TEST-STK] Firing smoke-test STK — phone=${phone} amount=${amount}`);
    try {
      const result = await this.daraja.stkPush({
        phone,
        amount,
        postId: 'test-smoke-test',
      });
      this.logger.log(`[TEST-STK] SUCCESS — ${JSON.stringify(result)}`);
      return { ok: true, phone, amount, ...result };
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      this.logger.error(`[TEST-STK] FAILED — phone=${phone} error=${detail}`);
      return { ok: false, phone, amount, error: detail };
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
      this.logger.error(
        `STK callback: no transaction for CheckoutRequestID ${checkoutRequestId}`,
      );
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
        (callback.CallbackMetadata as Record<string, unknown>)
          ?.Item as Array<{ Name: string; Value: unknown }>
      ) ?? [];
      const receipt = items.find((i) => i.Name === 'MpesaReceiptNumber')
        ?.Value as string | undefined;

      await this.transactions.update(transaction.id, {
        status: 'paid',
        mpesa_receipt: receipt ?? null,
      });
      this.logger.log(
        `Payment confirmed: transaction ${transaction.id}, receipt ${receipt}`,
      );

      await this.notifyProvider(transaction.post_id, transaction.id);
    } else {
      await this.transactions.update(transaction.id, { status: 'failed' });
      this.logger.warn(
        `Payment failed: transaction ${transaction.id} — ${resultDesc}`,
      );
    }
  }

  // ── Release payout (B2C) ───────────────────────────────────────────────────

  async releasePayout(dto: ReleasePayoutDto) {
    // Fetch post to resolve the selected provider.
    const { data: post, error: postError } = await this.supabase.client
      .from('posts')
      .select('id, title, selected_provider_id')
      .eq('id', dto.post_id)
      .single();

    if (postError || !post) {
      throw new NotFoundException(`Post ${dto.post_id} not found.`);
    }

    if (!post.selected_provider_id) {
      throw new BadRequestException('No provider has been selected for this post.');
    }

    // Fetch the confirmed paid transaction.
    const { data: transaction, error: txError } = await this.supabase.client
      .from('transactions')
      .select('*')
      .eq('post_id', dto.post_id)
      .eq('status', 'paid')
      .order('created_at', { ascending: false })
      .limit(1)
      .single();

    if (txError || !transaction) {
      throw new NotFoundException('No confirmed payment found for this post.');
    }

    if (transaction.status === 'released') {
      throw new ConflictException('Payout already released.');
    }
    if (transaction.status === 'payout_pending') {
      throw new ConflictException('Payout is already in progress.');
    }

    // Provider phone from users table — never from client.
    const { data: providerUser, error: providerError } = await this.supabase.client
      .from('users')
      .select('phone_number')
      .eq('id', post.selected_provider_id)
      .single();

    if (providerError || !providerUser) {
      throw new NotFoundException('Provider not found.');
    }

    const providerPhone = normalizePhone(providerUser.phone_number);
    this.logger.log(
      `[PAYOUT] Provider phone raw="${providerUser.phone_number ?? ''}" normalized="${providerPhone ?? 'null'}"`,
    );
    if (!providerPhone) {
      throw new BadRequestException(
        'Provider has not added a valid M-Pesa payout number.',
      );
    }

    const b2cResult = await this.daraja.b2cPayout({
      phone: providerPhone,
      amount: transaction.amount,
      jobId: dto.post_id,
    });

    await this.transactions.update(transaction.id, {
      status: 'payout_pending',
      conversation_id: b2cResult.conversationId,
    });

    const { error: escrowError } = await this.supabase.client
      .from('escrow')
      .update({ status: 'payout_pending', provider_id: post.selected_provider_id })
      .eq('transaction_id', transaction.id);

    if (escrowError) {
      this.logger.error(
        `Failed to update escrow for transaction ${transaction.id}: ${escrowError.message}`,
      );
    }

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

    const transaction = await this.transactions.findByConversationId(conversationId);
    if (!transaction) {
      this.logger.error(
        `B2C callback: no transaction for ConversationID ${conversationId}`,
      );
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
          `[CRITICAL] B2C succeeded but failed to update escrow for transaction ${transaction.id}: ${error.message}`,
        );
      }

      this.logger.log(`Payout released: transaction ${transaction.id}`);
    } else {
      await this.transactions.update(transaction.id, {
        status: 'paid',
        conversation_id: null,
      });

      const { error } = await this.supabase.client
        .from('escrow')
        .update({ status: 'locked', provider_id: null })
        .eq('transaction_id', transaction.id);

      if (error) {
        this.logger.error(
          `Failed to revert escrow after B2C failure for transaction ${transaction.id}: ${error.message}`,
        );
      }

      this.logger.warn(
        `B2C payout failed for transaction ${transaction.id}: ${resultDesc}`,
      );
    }
  }

  // ── Payment status (polled by Flutter) ─────────────────────────────────────

  async getStatus(postId: string) {
    const { data, error } = await this.supabase.client
      .from('transactions')
      .select('id, post_id, amount, fee, total_paid, status, mpesa_receipt, created_at, escrow(status, provider_id, released_at)')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .single();

    if (error || !data) {
      throw new NotFoundException(`No transaction found for post ${postId}.`);
    }

    return data;
  }

  // ── FCM provider notification ───────────────────────────────────────────────

  private async notifyProvider(postId: string, transactionId: string): Promise<void> {
    try {
      const { data: post } = await this.supabase.client
        .from('posts')
        .select('selected_provider_id, title')
        .eq('id', postId)
        .single();

      if (!post?.selected_provider_id) return;

      const { data: user } = await this.supabase.client
        .from('users')
        .select('fcm_tokens')
        .eq('id', post.selected_provider_id)
        .single();

      const tokens: string[] = Array.isArray(user?.fcm_tokens) ? (user.fcm_tokens as string[]) : [];
      if (tokens.length === 0) return;

      const serverKey = process.env.FCM_SERVER_KEY;
      if (!serverKey) {
        this.logger.warn('[FCM] FCM_SERVER_KEY not configured — provider notification skipped');
        return;
      }

      await axios.post(
        'https://fcm.googleapis.com/fcm/send',
        {
          registration_ids: tokens,
          notification: {
            title: 'Payment Secured!',
            body: `Payment secured for "${post.title}". Complete the job to receive your payout.`,
          },
          data: {
            type: 'payment_secured',
            post_id: postId,
            transaction_id: transactionId,
          },
        },
        {
          headers: {
            Authorization: `key=${serverKey}`,
            'Content-Type': 'application/json',
          },
        },
      );

      this.logger.log(`[FCM] Provider notified for post ${postId}, transaction ${transactionId}`);
    } catch (err) {
      this.logger.error(`[FCM] Failed to notify provider for post ${postId}: ${err}`);
    }
  }
}
