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
