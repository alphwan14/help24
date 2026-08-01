import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { ProvidersService } from './providers.service';
import { RegisterProviderDto } from './dto/register-provider.dto';
import { VerifyPayoutDto } from './dto/verify-payout.dto';
import { ChangePayoutDto } from './dto/change-payout.dto';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';

@Controller('providers')
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
