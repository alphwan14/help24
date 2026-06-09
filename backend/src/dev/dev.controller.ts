import { BadRequestException, Body, Controller, HttpCode, HttpStatus, Logger, Post } from '@nestjs/common';
import { DevService } from './dev.service';

/**
 * DEV / sandbox endpoints — all guarded inside DevService by MPESA_ENV check.
 * These routes are registered in production but throw 403 ForbiddenException.
 *
 * POST /dev/reset-state           — wipe transactions/escrow/events for a post_id
 * POST /dev/trigger-event         — inject + immediately process any event type
 * POST /mpesa/dev/reset-payment-lock  → handled in MpesaController
 */
@Controller('dev')
export class DevController {
  private readonly logger = new Logger(DevController.name);

  constructor(private readonly dev: DevService) {}

  /**
   * Clear all pending state for a post so the flow can be retested.
   * Body: { "post_id": "uuid" }
   */
  @Post('reset-state')
  @HttpCode(HttpStatus.OK)
  async resetState(@Body() body: { post_id?: string }) {
    if (!body?.post_id) throw new BadRequestException('post_id is required');
    this.logger.warn(`[DEV] POST /dev/reset-state — post=${body.post_id}`);
    return this.dev.resetState(body.post_id);
  }

  /**
   * FCM isolation test — bypass the full notification pipeline and send a test
   * push directly to the user's registered tokens (or to a raw token string).
   *
   * Body: { "userId": "string", "token"?: "raw FCM token" }
   *
   * If token is omitted: queries fcm_tokens table then falls back to
   * users.fcm_tokens JSONB and logs exactly what it finds.
   * If token is provided: skips DB lookup and sends to that token directly.
   */
  @Post('test-fcm')
  @HttpCode(HttpStatus.OK)
  async testFcm(@Body() body: { userId?: string; token?: string }) {
    if (!body?.userId) throw new BadRequestException('userId is required');
    this.logger.warn(`[DEV] POST /dev/test-fcm — userId=${body.userId}`);
    return this.dev.testFcm(body.userId, body.token);
  }

  /**
   * Inject any canonical event and process it immediately.
   * Body: { "event": "payment.success", "postId": "uuid", "payload": {} }
   *
   * Extra payload fields are merged with { post_id } in the event payload.
   * Required by event handlers: see event-processor.service.ts for each type's
   * expected payload shape.
   */
  @Post('trigger-event')
  @HttpCode(HttpStatus.OK)
  async triggerEvent(
    @Body() body: { event?: string; postId?: string; payload?: Record<string, unknown> },
  ) {
    if (!body?.event)  throw new BadRequestException('event is required');
    if (!body?.postId) throw new BadRequestException('postId is required');
    this.logger.warn(`[DEV] POST /dev/trigger-event — type=${body.event} post=${body.postId}`);
    return this.dev.triggerEvent(body.event, body.postId, body.payload ?? {});
  }
}
