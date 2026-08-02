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
  UseGuards,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { MpesaService } from './mpesa.service';
import { InitiatePaymentDto } from './dto/initiate-payment.dto';
import { ReleasePayoutDto } from './dto/release-payout.dto';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { AdminAuth, Auth, Public } from '../common/auth/auth.decorator';
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';

@Controller('mpesa')
export class MpesaController {
  private readonly logger = new Logger(MpesaController.name);

  constructor(
    private readonly mpesa: MpesaService,
    private readonly config: ConfigService,
  ) {}

  @Post('initiate')
  @HttpCode(HttpStatus.CREATED)
  @RateLimit('payments:initiate')
  // Every call pushes a PIN prompt to the phone on file for `buyer_user_id`.
  // Unbound, that is a way to make someone else's phone ask them to pay.
  @Auth('body.buyer_user_id')
  initiatePayment(@Body() dto: InitiatePaymentDto) {
    this.logger.log(`[STK] initiate — post=${dto.post_id} buyer=${dto.buyer_user_id}`);
    return this.mpesa.initiatePayment(dto);
  }

  /**
   * Smoke-test — caller supplies phone and optional amount (defaults to 1).
   *
   * WAS the most abusable endpoint on this API: unauthenticated, reachable in
   * production, and it pushes an M-Pesa PIN prompt to ANY phone number in the
   * request body — a harassment tool and a Daraja quota burner. The Phase 1
   * rate limit (3/hour per IP) contained it without fixing it, and the security
   * report's recommendation was to gate it out of production entirely.
   *
   * Now closed on both axes it was open on: it requires an authenticated caller,
   * and `MpesaService.testStk` refuses outright when MPESA_ENV=production — the
   * same check the /mpesa/dev/* routes already use. Authentication alone would
   * not have been enough; any signed-up account could still have used it to
   * prompt arbitrary numbers.
   */
  @Post('test-stk')
  @HttpCode(HttpStatus.OK)
  @RateLimit('payments:smoke')
  @Auth()
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
  @RateLimit('payments:callback')
  // Safaricom posts here from its own infrastructure with no credential we can
  // check. Requiring one would mean dropping genuine callbacks — a payment
  // taken from a user with no job funded, resolvable only by hand. The
  // authenticity control is inside the service (a callback must match a pending
  // transaction by CheckoutRequestID), not at the door.
  @Public('Daraja posts payment results here unauthenticated. Rejecting a genuine callback loses money.')
  stkCallback(@Body() body: Record<string, unknown>) {
    this.logger.log(`[STK] callback received: ${JSON.stringify(body)}`);
    return this.mpesa.handleStkCallback(body);
  }

  /**
   * Manual escrow release.
   *
   * ADMIN-ONLY, and it was not before. The body carries only `post_id`, so
   * there is no caller to bind — anyone who knew a post id could ask for its
   * escrow to be paid out. Nothing legitimate is lost by closing it: the normal
   * payout path is the `payment.payout_requested` event, which calls
   * `MpesaService.releasePayout` in-process and never touches this route, and
   * the mobile app declares a constant for it that no code path uses. What
   * remains is manual operator intervention, which is what the admin token is for.
   */
  @Post('release-payout')
  @HttpCode(HttpStatus.OK)
  @RateLimit('payments:release')
  @UseGuards(AdminAuthGuard)
  @AdminAuth()
  releasePayout(@Body() dto: ReleasePayoutDto) {
    return this.mpesa.releasePayout(dto);
  }

  // Daraja sends raw JSON — skip DTO validation, accept as-is.
  @Post('b2c-callback')
  @HttpCode(HttpStatus.OK)
  @RateLimit('payments:callback')
  @Public('Daraja posts payout results here unauthenticated. Same reasoning as stk-callback.')
  b2cCallback(@Body() body: Record<string, unknown>) {
    this.logger.log(`[B2C] callback received: ${JSON.stringify(body)}`);
    return this.mpesa.handleB2cCallback(body);
  }

  // Daraja Transaction Status Query RESULT — the async answer to an admin
  // reconcile. Public (Daraja posts here, unauthenticated); settlement is
  // guarded inside the service (settles only on a confirmed terminal status).
  @Post('b2c-status-result')
  @HttpCode(HttpStatus.OK)
  @RateLimit('payments:callback')
  @Public('Daraja posts transaction-status results here unauthenticated.')
  b2cStatusResult(@Body() body: Record<string, unknown>) {
    this.logger.log(`[B2C] status-result received: ${JSON.stringify(body)}`);
    return this.mpesa.handleB2cStatusResult(body);
  }

  @Get('status/:postId')
  @RateLimit('payments:read')
  // Payment state for one job. No identity field to bind (the post id is the
  // only argument), but it is not public information — a signed-in caller is
  // required. Participant-scoping needs a service change; see the security review.
  @Auth()
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
  @RateLimit('dev:harness')
  @Auth()
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
  @RateLimit('dev:harness')
  @Auth()
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
  @RateLimit('health:deep')
  // Configuration echo with every secret masked. Its audience is an operator
  // diagnosing a misrouted Daraja callback, often before any account exists on
  // the instance being checked.
  @Public('Deployment configuration check. All secrets are masked in the response.')
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
