import {
  BadRequestException,
  ConflictException,
  Injectable,
  InternalServerErrorException,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { randomInt, timingSafeEqual } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';
import { RegisterProviderDto } from './dto/register-provider.dto';
import { VerifyPayoutDto } from './dto/verify-payout.dto';
import { ChangePayoutDto } from './dto/change-payout.dto';

@Injectable()
export class ProvidersService {
  private readonly logger = new Logger(ProvidersService.name);

  constructor(private readonly supabase: SupabaseService) {}

  async register(dto: RegisterProviderDto): Promise<{ provider_id: string }> {
    // Reject duplicate phone_login
    const { data: existing } = await this.supabase.client
      .from('providers')
      .select('id')
      .eq('phone_login', dto.phone_login)
      .maybeSingle();

    if (existing) {
      throw new ConflictException(
        `Phone number ${dto.phone_login} is already registered as a provider`,
      );
    }

    const { data: provider, error } = await this.supabase.client
      .from('providers')
      .insert({
        name: dto.name,
        phone_login: dto.phone_login,
        phone_payout: dto.phone_payout,
        services: dto.services,
        location: dto.location,
        payout_verified: false,
      })
      .select('id')
      .single();

    if (error || !provider) {
      throw new InternalServerErrorException(
        `Registration failed: ${error?.message}`,
      );
    }

    await this.issuePayoutOtp(provider.id, dto.phone_payout);

    return { provider_id: provider.id };
  }

  async verifyPayout(dto: VerifyPayoutDto): Promise<void> {
    const { data: verification, error } = await this.supabase.client
      .from('phone_verifications')
      .select('id, otp_code, expires_at')
      .eq('provider_id', dto.provider_id)
      .eq('type', 'payout')
      .eq('status', 'pending')
      .gt('expires_at', new Date().toISOString())
      .order('created_at', { ascending: false })
      .limit(1)
      .single();

    if (error || !verification) {
      throw new BadRequestException('OTP expired or not found. Request a new code.');
    }

    if (!this.safeEqual(dto.otp_code, verification.otp_code)) {
      throw new BadRequestException('Invalid OTP code.');
    }

    const { error: markError } = await this.supabase.client
      .from('phone_verifications')
      .update({ status: 'verified' })
      .eq('id', verification.id);

    if (markError) {
      throw new InternalServerErrorException('Failed to mark OTP as verified.');
    }

    const { error: providerError } = await this.supabase.client
      .from('providers')
      .update({ payout_verified: true })
      .eq('id', dto.provider_id);

    if (providerError) {
      throw new InternalServerErrorException('Failed to update provider verification status.');
    }
  }

  async changePayout(dto: ChangePayoutDto): Promise<void> {
    const { data: provider, error } = await this.supabase.client
      .from('providers')
      .select('id, phone_payout')
      .eq('id', dto.provider_id)
      .single();

    if (error || !provider) {
      throw new NotFoundException(`Provider ${dto.provider_id} not found.`);
    }

    if (provider.phone_payout === dto.new_phone_payout) {
      throw new BadRequestException('New payout number is the same as the current one.');
    }

    // Reset verified flag and update phone atomically
    const { error: updateError } = await this.supabase.client
      .from('providers')
      .update({ phone_payout: dto.new_phone_payout, payout_verified: false })
      .eq('id', dto.provider_id);

    if (updateError) {
      throw new InternalServerErrorException('Failed to update payout number.');
    }

    // Expire any pending OTPs before issuing a new one
    await this.supabase.client
      .from('phone_verifications')
      .update({ status: 'expired' })
      .eq('provider_id', dto.provider_id)
      .eq('type', 'payout')
      .eq('status', 'pending');

    await this.issuePayoutOtp(dto.provider_id, dto.new_phone_payout);
  }

  private async issuePayoutOtp(providerId: string, phone: string): Promise<void> {
    const otp = randomInt(100_000, 1_000_000).toString();
    const expiresAt = new Date(Date.now() + 5 * 60 * 1_000).toISOString();

    const { error } = await this.supabase.client.from('phone_verifications').insert({
      provider_id: providerId,
      phone,
      otp_code: otp,
      type: 'payout',
      status: 'pending',
      expires_at: expiresAt,
    });

    if (error) {
      throw new InternalServerErrorException('Failed to issue OTP.');
    }

    // TODO: Replace with SMS provider (Africa's Talking / Twilio)
    this.logger.log(`[OTP] Issued for provider ${providerId} → ${phone}`);
  }

  private safeEqual(a: string, b: string): boolean {
    if (a.length !== b.length) return false;
    return timingSafeEqual(Buffer.from(a), Buffer.from(b));
  }
}
