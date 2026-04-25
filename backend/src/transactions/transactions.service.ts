import { Injectable, InternalServerErrorException } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';

export interface Transaction {
  id: string;
  post_id: string;
  buyer_user_id: string;
  phone: string;
  amount: number;
  fee: number;
  total_paid: number;
  status: string;
  checkout_request_id: string | null;
  conversation_id: string | null;
  mpesa_receipt: string | null;
  created_at: string;
}

@Injectable()
export class TransactionsService {
  constructor(private readonly supabase: SupabaseService) {}

  async create(data: {
    postId: string;
    buyerUserId: string;
    phone: string;
    amount: number;
    fee: number;
    totalPaid: number;
  }): Promise<Transaction> {
    const { data: tx, error } = await this.supabase.client
      .from('transactions')
      .insert({
        post_id: data.postId,
        buyer_user_id: data.buyerUserId,
        phone: data.phone,
        amount: data.amount,
        fee: data.fee,
        total_paid: data.totalPaid,
        status: 'pending',
      })
      .select()
      .single();

    if (error || !tx) {
      throw new InternalServerErrorException(
        `Failed to create transaction: ${error?.message}`,
      );
    }
    return tx as Transaction;
  }

  async findByCheckoutRequestId(checkoutRequestId: string): Promise<Transaction | null> {
    const { data, error } = await this.supabase.client
      .from('transactions')
      .select('*')
      .eq('checkout_request_id', checkoutRequestId)
      .single();

    if (error) return null;
    return data as Transaction;
  }

  async findByConversationId(conversationId: string): Promise<Transaction | null> {
    const { data, error } = await this.supabase.client
      .from('transactions')
      .select('*')
      .eq('conversation_id', conversationId)
      .single();

    if (error) return null;
    return data as Transaction;
  }

  async findLatestByPostId(postId: string): Promise<Transaction | null> {
    const { data, error } = await this.supabase.client
      .from('transactions')
      .select('*')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .single();

    if (error) return null;
    return data as Transaction;
  }

  async update(id: string, data: Record<string, unknown>): Promise<void> {
    const { error } = await this.supabase.client
      .from('transactions')
      .update(data)
      .eq('id', id);

    if (error) {
      throw new InternalServerErrorException(
        `Failed to update transaction ${id}: ${error.message}`,
      );
    }
  }
}
