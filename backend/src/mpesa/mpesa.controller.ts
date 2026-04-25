import {
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Post,
} from '@nestjs/common';
import { MpesaService } from './mpesa.service';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ReleasePayoutDto } from './dto/release-payout.dto';

@Controller('mpesa')
export class MpesaController {
  constructor(private readonly mpesa: MpesaService) {}

  @Post('initiate')
  @HttpCode(HttpStatus.CREATED)
  initiatePayment(@Body() dto: InitiatePaymentDto) {
    return this.mpesa.initiatePayment(dto);
  }

  // Daraja sends raw JSON — skip DTO validation, accept as-is.
  @Post('stk-callback')
  @HttpCode(HttpStatus.OK)
  stkCallback(@Body() body: Record<string, unknown>) {
    return this.mpesa.handleStkCallback(body);
  }

  @Post('release-payout')
  @HttpCode(HttpStatus.OK)
  releasePayout(@Body() dto: ReleasePayoutDto) {
    return this.mpesa.releasePayout(dto);
  }

  // Daraja sends raw JSON — skip DTO validation, accept as-is.
  @Post('b2c-callback')
  @HttpCode(HttpStatus.OK)
  b2cCallback(@Body() body: Record<string, unknown>) {
    return this.mpesa.handleB2cCallback(body);
  }

  @Get('status/:postId')
  getStatus(@Param('postId') postId: string) {
    return this.mpesa.getStatus(postId);
  }
}
