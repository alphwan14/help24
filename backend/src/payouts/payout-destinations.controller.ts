import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  ParseUUIDPipe,
  Post,
  Query,
} from '@nestjs/common';
import { AuthCritical } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import {
  AddDestinationDto,
  ListDestinationsQueryDto,
  RequestChallengeDto,
  RetireDestinationDto,
  SetDefaultDto,
  VerifyChallengeDto,
} from './dto/payout-destination.dtos';
import { PayoutOnboardingService } from './payout-onboarding.service';

/**
 * The HTTP layer the payouts module deliberately shipped without — added now
 * that the OTP flow exists, which is the condition the module comment set.
 *
 * Ownership model: every route binds the caller's verified uid onto
 * `user_id`, and the service scopes every read and write to
 * `provider_user_id = user_id`. A destination someone else owns is
 * indistinguishable from one that does not exist.
 *
 * The whole surface answers 503 until PAYOUT_DESTINATIONS_ENABLED=true — same
 * switch, same rollout order as the resolve path (apply migrations → enable →
 * watch → tighten).
 */
@Controller('payout-destinations')
export class PayoutDestinationsController {
  constructor(private readonly onboarding: PayoutOnboardingService) {}

  /** The provider's own destinations, newest first, with live challenge state. */
  @Get()
  @RateLimit('payout:read')
  @AuthCritical('query.user_id')
  async list(@Query() query: ListDestinationsQueryDto) {
    this.onboarding.assertEnabled();
    return { destinations: await this.onboarding.list(query.user_id) };
  }

  /**
   * Add a payout number. Creates the pending destination and issues its OTP in
   * one step — a destination nothing can prove is not worth a round trip.
   */
  @Post()
  @HttpCode(HttpStatus.CREATED)
  @RateLimit('payout:issue')
  @AuthCritical('body.user_id')
  async add(@Body() dto: AddDestinationDto) {
    this.onboarding.assertEnabled();
    return { destination: await this.onboarding.add(dto.user_id, dto.msisdn) };
  }

  /** Resend the code for a pending destination (cooldown-limited). */
  @Post(':id/challenge')
  @HttpCode(HttpStatus.OK)
  @RateLimit('payout:issue')
  @AuthCritical('body.user_id')
  async requestChallenge(
    @Param('id', new ParseUUIDPipe()) id: string,
    @Body() dto: RequestChallengeDto,
  ) {
    this.onboarding.assertEnabled();
    return { verification: await this.onboarding.requestChallenge(dto.user_id, id) };
  }

  /**
   * Prove the number. On success the destination becomes active and (unless
   * make_default=false) the default that new escrows will freeze.
   */
  @Post(':id/verify')
  @HttpCode(HttpStatus.OK)
  @RateLimit('payout:verify')
  @AuthCritical('body.user_id')
  async verify(
    @Param('id', new ParseUUIDPipe()) id: string,
    @Body() dto: VerifyChallengeDto,
  ) {
    this.onboarding.assertEnabled();
    const destination = await this.onboarding.verify(
      dto.user_id,
      id,
      dto.code,
      dto.make_default !== false,
    );
    return { outcome: 'verified', destination };
  }

  /** Choose which active destination new escrows freeze. */
  @Post(':id/default')
  @HttpCode(HttpStatus.OK)
  @RateLimit('payout:manage')
  @AuthCritical('body.user_id')
  async setDefault(
    @Param('id', new ParseUUIDPipe()) id: string,
    @Body() dto: SetDefaultDto,
  ) {
    this.onboarding.assertEnabled();
    return { destination: await this.onboarding.setDefault(dto.user_id, id) };
  }

  /**
   * Retire a destination. Deliberately does not auto-promote a replacement
   * default — choosing where money goes next is the provider's decision, and
   * new escrows refuse until they make it.
   */
  @Post(':id/retire')
  @HttpCode(HttpStatus.OK)
  @RateLimit('payout:manage')
  @AuthCritical('body.user_id')
  async retire(
    @Param('id', new ParseUUIDPipe()) id: string,
    @Body() dto: RetireDestinationDto,
  ) {
    this.onboarding.assertEnabled();
    await this.onboarding.retire(dto.user_id, id, dto.reason);
    return { ok: true };
  }
}
