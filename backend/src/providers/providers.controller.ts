import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { ProvidersService } from './providers.service';
import { RegisterProviderDto } from './dto/register-provider.dto';
import { VerifyPayoutDto } from './dto/verify-payout.dto';
import { ChangePayoutDto } from './dto/change-payout.dto';

@Controller('providers')
export class ProvidersController {
  constructor(private readonly providers: ProvidersService) {}

  @Post('register')
  @HttpCode(HttpStatus.CREATED)
  register(@Body() dto: RegisterProviderDto) {
    return this.providers.register(dto);
  }

  @Post('verify-payout')
  @HttpCode(HttpStatus.OK)
  verifyPayout(@Body() dto: VerifyPayoutDto) {
    return this.providers.verifyPayout(dto);
  }

  @Post('change-payout')
  @HttpCode(HttpStatus.OK)
  changePayout(@Body() dto: ChangePayoutDto) {
    return this.providers.changePayout(dto);
  }
}
