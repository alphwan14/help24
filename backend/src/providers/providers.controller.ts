import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { ProvidersService } from './providers.service';
import { RegisterProviderDto } from './dto/register-provider.dto';
import { VerifyPayoutDto } from './dto/verify-payout.dto';
import { ChangePayoutDto } from './dto/change-payout.dto';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { Auth } from '../common/auth/auth.decorator';

/**
 * Legacy provider registration + payout-number verification.
 *
 * ⚠️ NO OWNERSHIP MODEL EXISTS ON THIS SURFACE, AND AUTHENTICATION DOES NOT
 *    CREATE ONE.
 *
 * `providers.id` is a table UUID with no column linking it to a Firebase user,
 * so there is nothing for `@Auth` to bind: the guard can prove WHO is calling
 * but not that they own the provider record they named. `@Auth()` therefore
 * narrows the attacker set from "anyone on the internet" to "anyone with a
 * Help24 account" and no further.
 *
 * What that leaves open, stated plainly: `POST /providers/change-payout` writes
 * the new payout number FIRST and then issues the OTP TO THAT NEW NUMBER, so a
 * caller who knows a provider UUID can point payouts at their own phone and
 * then verify it themselves. The only thing containing it today is that this
 * subsystem is orphaned — `providers.phone_payout` is written here and read by
 * nothing in the B2C payout path, and the mobile app never calls these routes.
 *
 * Closing it properly means adding an owner column and checking it, which is a
 * schema change, not an authentication change. It is written up in the security
 * review as the highest-priority follow-up; deliberately NOT bundled into this
 * migration, whose promise is that no business logic changes shape.
 */
@Controller('providers')
@Auth()
export class ProvidersController {
  constructor(private readonly providers: ProvidersService) {}

  @Post('register')
  @HttpCode(HttpStatus.CREATED)
  @RateLimit('otp:issue')
  register(@Body() dto: RegisterProviderDto) {
    return this.providers.register(dto);
  }

  // The OTP brute-force boundary. Before this phase this endpoint had no
  // limit of any kind against a 6-digit code — see the otp:verify rationale.
  @Post('verify-payout')
  @HttpCode(HttpStatus.OK)
  @RateLimit('otp:verify')
  verifyPayout(@Body() dto: VerifyPayoutDto) {
    return this.providers.verifyPayout(dto);
  }

  @Post('change-payout')
  @HttpCode(HttpStatus.OK)
  @RateLimit('otp:issue')
  changePayout(@Body() dto: ChangePayoutDto) {
    return this.providers.changePayout(dto);
  }
}
