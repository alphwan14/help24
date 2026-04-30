import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  HttpStatus,
  Logger,
  Param,
  Post,
} from '@nestjs/common';
import { MpesaService } from './mpesa.service';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ReleasePayoutDto } from './dto/release-payout.dto';

@Controller('mpesa')
export class MpesaController {
  private readonly logger = new Logger(MpesaController.name);

  constructor(private readonly mpesa: MpesaService) {}

  @Post('initiate')
  @HttpCode(HttpStatus.CREATED)
  initiatePayment(@Body() dto: InitiatePaymentDto) {
    this.logger.log(`[STK] initiate — post=${dto.post_id} buyer=${dto.buyer_user_id}`);
    return this.mpesa.initiatePayment(dto);
  }

  /** Sandbox smoke-test — caller supplies phone, amount is fixed at 1. */
  @Post('test-stk')
  @HttpCode(HttpStatus.OK)
  testStk(@Body() body: { phone?: string }) {
    const phone = body?.phone?.trim() ?? '';
    if (!phone) throw new BadRequestException('phone is required in request body');
    this.logger.log(`[TEST-STK] endpoint called — phone=${phone}`);
    return this.mpesa.testStk(phone);
  }

  // Daraja sends raw JSON — skip DTO validation, accept as-is.
  @Post('stk-callback')
  @HttpCode(HttpStatus.OK)
  stkCallback(@Body() body: Record<string, unknown>) {
    this.logger.log(`[STK] callback received: ${JSON.stringify(body)}`);
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
    this.logger.log(`[B2C] callback received: ${JSON.stringify(body)}`);
    return this.mpesa.handleB2cCallback(body);
  }

  @Get('status/:postId')
  getStatus(@Param('postId') postId: string) {
    return this.mpesa.getStatus(postId);
  }
}
