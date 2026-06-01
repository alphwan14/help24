import { Body, Controller, Get, Param, Post, Query } from '@nestjs/common';
import { EventProcessorService } from './event-processor.service';
import { EventsService } from './events.service';

/**
 * Admin endpoints for event observability and debugging.
 *
 * Base path: /admin/events
 *
 * GET  /admin/events            — list recent events (filterable)
 * GET  /admin/events/:id        — single event detail
 * POST /admin/events/replay     — manually re-run an event handler
 * GET  /admin/events/dead-letter — all permanently-failed events
 */
@Controller('admin/events')
export class EventsAdminController {
  constructor(
    private readonly processor: EventProcessorService,
    private readonly events: EventsService,
  ) {}

  /**
   * List recent events.
   *
   * Query params:
   *   processed=true|false  — filter by processed flag
   *   dead_letter=true|false — filter by dead_letter flag
   *   limit=N               — max rows (default 100)
   *   since=ISO8601          — only events after this timestamp
   *
   * Example:
   *   GET /admin/events?processed=false
   *   GET /admin/events?dead_letter=true
   *   GET /admin/events?processed=false&limit=20
   */
  @Get()
  list(
    @Query('processed')   processed?: string,
    @Query('dead_letter') deadLetter?: string,
    @Query('limit')       limit?: string,
    @Query('since')       since?: string,
  ) {
    return this.events.list({
      processed:   processed  !== undefined ? processed  === 'true' : undefined,
      deadLetter:  deadLetter !== undefined ? deadLetter === 'true' : undefined,
      limit:       limit ? Math.min(parseInt(limit, 10), 500) : 100,
      since,
    });
  }

  /**
   * Get a single event by ID.
   * Use this to inspect exact payload and error details.
   *
   * Example:
   *   GET /admin/events/f47ac10b-58cc-4372-a567-0e02b2c3d479
   */
  @Get('dead-letter')
  listDeadLetter(@Query('limit') limit?: string) {
    return this.events.list({
      deadLetter: true,
      limit: limit ? Math.min(parseInt(limit, 10), 500) : 100,
    });
  }

  @Get(':id')
  getById(@Param('id') id: string) {
    return this.events.fetchById(id);
  }

  /**
   * Replay an event manually.
   * Works on any event: pending, failed, or dead-letter.
   * Resets retry_count and dead_letter=false before running the handler.
   *
   * Body: { "eventId": "uuid" }
   *
   * Example:
   *   POST /admin/events/replay
   *   { "eventId": "f47ac10b-58cc-4372-a567-0e02b2c3d479" }
   */
  @Post('replay')
  replay(@Body() body: { eventId: string }) {
    return this.processor.replayById(body.eventId);
  }
}
