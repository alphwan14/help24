import { Controller, Get, UseGuards } from '@nestjs/common';
import { EventProcessorService } from './event-processor.service';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { AdminAuth } from '../common/auth/auth.decorator';
import { AdminAuthGuard } from '../admin/auth/admin-auth.guard';

/**
 * GET /health/events
 *
 * Returns the live status of EventProcessorService.
 *
 * Response shape:
 * {
 *   "processorAlive": true,          // false if loop hasn't ticked in 120s
 *   "startedAt":      "2024-...",    // when the processor module initialized
 *   "lastTickAt":     "2024-...",    // when the retry loop last ran
 *   "lastProcessedAt": "2024-..." | null,  // when an event was last handled OK
 *   "tickCount":      42,            // total loop iterations since startup
 *   "queueSize":      3,             // unprocessed non-dead-letter events
 *   "deadLetterCount": 0             // permanently failed events
 * }
 *
 * Use processorAlive=false + queueSize>0 as the "something is stuck" signal.
 * Use deadLetterCount>0 as the "events need manual replay" signal.
 */
// Counters only — queue depth and tick timestamps, never an event's contents.
// Still internal — how Help24 processes events is not the public's to read —
// so it needs a signed-in admin (2026-10-30).
@Controller('health/events')
@RateLimit('health:deep')
@UseGuards(AdminAuthGuard)
@AdminAuth()
export class EventsHealthController {
  constructor(private readonly processor: EventProcessorService) {}

  @Get()
  check() {
    return this.processor.getHealthStatus();
  }
}
