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
import { ConfigService } from '@nestjs/config';
import { MpesaService } from './mpesa.service';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ReleasePayoutDto } from './dto/release-payout.dto';

@Controller('mpesa')
export class MpesaController {
  private readonly logger = new Logger(MpesaController.name);

  constructor(
    private readonly mpesa: MpesaService,
    private readonly config: ConfigService,
  ) {}

  @Post('initiate')
  @HttpCode(HttpStatus.CREATED)
  initiatePayment(@Body() dto: InitiatePaymentDto) {
    this.logger.log(`[STK] initiate — post=${dto.post_id} buyer=${dto.buyer_user_id}`);
    return this.mpesa.initiatePayment(dto);
  }

  /** Smoke-test — caller supplies phone and optional amount (defaults to 1). */
  @Post('test-stk')
  @HttpCode(HttpStatus.OK)
  testStk(@Body() body: { phone?: string; amount?: number }) {
    const phone = body?.phone?.trim() ?? '';
    if (!phone) throw new BadRequestException('phone is required in request body');
    const amount = Number(body?.amount ?? 1);
    this.logger.log(`[TEST-STK] endpoint called — phone=${phone} amount=${amount}`);
    return this.mpesa.testStk(phone, amount);
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

  /**
   * DEV / sandbox ONLY — forces a pending transaction to paid.
   * ⚠️  Returns 403 ForbiddenException in production (MPESA_ENV=production).
   * POST /mpesa/dev/force-success
   */
  @Post('dev/force-success')
  @HttpCode(HttpStatus.OK)
  forceSuccess(@Body() body: { post_id?: string }) {
    if (!body?.post_id) throw new BadRequestException('post_id is required');
    this.logger.warn(`[DEV] force-success endpoint called — post=${body.post_id}`);
    return this.mpesa.forceSuccessForDev(body.post_id);
  }

  /**
   * DEV / sandbox ONLY — clears a stuck pending-transaction lock so a new
   * STK push can be initiated for the same post.
   * ⚠️  Returns 403 ForbiddenException in production (MPESA_ENV=production).
   * POST /mpesa/dev/reset-payment-lock
   */
  @Post('dev/reset-payment-lock')
  @HttpCode(HttpStatus.OK)
  resetPaymentLock(@Body() body: { post_id?: string }) {
    if (!body?.post_id) throw new BadRequestException('post_id is required');
    this.logger.warn(`[DEV] reset-payment-lock endpoint called — post=${body.post_id}`);
    return this.mpesa.resetPaymentLockForDev(body.post_id);
  }

  /**
   * Health/config check — shows what environment this instance is running with.
   * Secrets are masked. Use this to verify production Render env vars are correct.
   * GET /mpesa/health
   */
  @Get('health')
  @HttpCode(HttpStatus.OK)
  health() {
    const env         = this.config.get<string>('MPESA_ENV', 'MISSING');
    const shortcode   = this.config.get<string>('MPESA_SHORTCODE', 'MISSING');
    const callbackUrl = this.config.get<string>('MPESA_CALLBACK_URL', 'MISSING');
    const b2cResultUrl= this.config.get<string>('MPESA_B2C_RESULT_URL', 'MISSING');
    const consumerKey = this.config.get<string>('MPESA_CONSUMER_KEY', '');

    // Mask middle of secrets so they're identifiable but not exposed.
    const mask = (s: string) =>
      s.length > 8 ? `${s.slice(0, 4)}…${s.slice(-4)}` : '****';

    const callbackOk = callbackUrl.startsWith('https://') &&
      callbackUrl.includes('/mpesa/stk-callback') &&
      !callbackUrl.includes('ngrok') &&
      !callbackUrl.includes('localhost');

    return {
      mpesa_env:      env,
      shortcode,
      callback_url:   callbackUrl,
      callback_ok:    callbackOk,
      callback_warning: callbackOk ? null :
        'MPESA_CALLBACK_URL appears to be a local/tunnel URL. ' +
        'Set it to https://help24-backend.onrender.com/mpesa/stk-callback in Render env vars.',
      b2c_result_url: b2cResultUrl,
      consumer_key:   mask(consumerKey),
      note: 'callback_ok=false means Daraja callbacks go to the wrong server — ' +
            'transactions will stay pending or be processed by a different instance.',
    };
  }
}
