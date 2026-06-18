import { Module } from '@nestjs/common';
import { SupabaseModule } from '../supabase/supabase.module';
import { ReputationService } from './reputation.service';
import { ReputationController } from './reputation.controller';

/**
 * Reputation engine module. Exports ReputationService so the event processor can
 * trigger recomputation on canonical lifecycle events (job approved, dispute
 * resolved, and — in Phase 3.2D — review created/edited/retracted).
 */
@Module({
  imports: [SupabaseModule],
  providers: [ReputationService],
  controllers: [ReputationController],
  exports: [ReputationService],
})
export class ReputationModule {}
