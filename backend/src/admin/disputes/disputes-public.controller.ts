import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { DisputesService } from './disputes.service';
import { CreateDisputeDto } from './dto/create-dispute.dto';

/**
 * User-facing dispute creation. Deliberately NOT behind the admin guard — the
 * raiser is a client/provider (Firebase user), identified by raised_by_user_id
 * and validated against the post's participants. Anti-spam + dedupe live in the
 * service.
 */
@Controller('disputes')
export class DisputesPublicController {
  constructor(private readonly disputes: DisputesService) {}

  @Post('create')
  @HttpCode(HttpStatus.CREATED)
  create(@Body() dto: CreateDisputeDto) {
    return this.disputes.createDispute(dto);
  }
}
