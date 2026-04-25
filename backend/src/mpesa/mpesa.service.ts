import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { TransactionsService } from '../transactions/transactions.service';
import { DarajaService } from './daraja.service';
import { calculateFee, calculateTotal } from './fee';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ReleasePayoutDto } from './dto/release-payout.dto';

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
    // Amount comes from DB — never trusted from the client.
    const { data: post, error: postError } = await this.supabase.client
      .from('posts')
      .select('id, price, author_user_id')
      .eq('id', dto.post_id)
      .single();

    if (postError || !post) {
      throw new NotFoundException(`Post ${dto.post_id} not found.`);
    }

    const amount = Math.round(Number(post.price));
    if (amount < 100) {
      throw new BadRequestException(
        'Post price is below the minimum payment threshold (100 KES).',
      );
    }

    const fee = calculateFee(amount);
    const totalPaid = calculateTotal(amount);

    // Record the transaction BEFORE calling Daraja — if the DB write after
    // STK push fails, the user would be charged with no record to reconcile.
    const transaction = await this.transactions.create({
      postId: dto.post_id,
      buyerUserId: dto.buyer_user_id,
      phone: dto.buyer_phone,
      amount,
      fee,
      totalPaid,
    });

    // Initiate STK push — buyer pays (amount + fee).
    let stkResult;
    try {
      stkResult = await this.daraja.stkPush({
        phone: dto.buyer_phone,
        amount: totalPaid,
        postId: dto.post_id,
      });
    } catch (err) {
      await this.transactions.update(transaction.id, { status: 'failed' });
      throw err;
    }

    // Stamp the checkout request ID now that Daraja accepted.
    await this.transactions.update(transaction.id, {
      checkout_request_id: stkResult.checkoutRequestId,
    });

    // Create escrow record — locked until STK callback confirms payment.
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

  // ── STK push callback (called by Daraja) ───────────────────────────────────

  async handleStkCallback(body: Record<string, unknown>): Promise<void> {
    const callback = (body?.Body as Record<string, unknown>)
      ?.stkCallback as Record<string, unknown> | undefined;

    if (!callback) {
      this.logger.warn('Received malformed STK callback — missing Body.stkCallback');
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

    // Idempotency — skip if already processed.
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
    } else {
      await this.transactions.update(transaction.id, { status: 'failed' });
      this.logger.warn(
        `Payment failed: transaction ${transaction.id} — ${resultDesc}`,
      );
    }
  }

  // ── Release payout (B2C) ───────────────────────────────────────────────────

  async releasePayout(dto: ReleasePayoutDto) {
    // Fetch the paid transaction for this post.
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

    // Provider phone comes from DB — never from the client.
    const { data: provider, error: providerError } = await this.supabase.client
      .from('providers')
      .select('id, phone_payout, payout_verified')
      .eq('id', dto.provider_id)
      .single();

    if (providerError || !provider) {
      throw new NotFoundException(`Provider ${dto.provider_id} not found.`);
    }
    if (!provider.payout_verified) {
      throw new BadRequestException('Provider payout number is not verified.');
    }

    // Amount from transaction record — never from the client.
    const b2cResult = await this.daraja.b2cPayout({
      phone: provider.phone_payout,
      amount: transaction.amount,
      jobId: dto.post_id,
    });

    await this.transactions.update(transaction.id, {
      status: 'payout_pending',
      conversation_id: b2cResult.conversationId,
    });

    const { error: escrowError } = await this.supabase.client
      .from('escrow')
      .update({ status: 'payout_pending', provider_id: dto.provider_id })
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
    const result = body?.Result as Record<string, unknown> | undefined;

    if (!result) {
      this.logger.warn('Received malformed B2C callback — missing Result');
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
      // Revert to 'paid' so payout can be retried.
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

  // ── Payment status (polled by Flutter JobStatusScreen) ─────────────────────

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
}
