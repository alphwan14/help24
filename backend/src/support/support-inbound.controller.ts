import {
  BadRequestException,
  Body,
  Controller,
  HttpCode,
  HttpStatus,
  Logger,
  Post,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Public } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { SupportService } from './support.service';
import { InboundDeliveryDto } from './dto/support.dto';
import { parseInbound, verifyInbound } from './support-rules';

/**
 * POST /support/inbound-email: mail to support@ and info@, delivered by the
 * Cloudflare Email Worker (workers/help24-mail).
 *
 * Public at the door because the Worker holds no admin or member token; the
 * control is the signature. The Worker signs "<timestamp>.<payload>" with
 * SUPPORT_INBOUND_SECRET, and anything unsigned, mis-signed or older than five
 * minutes is refused before the payload is even decoded.
 */
@Controller('support')
export class SupportInboundController {
  private readonly logger = new Logger(SupportInboundController.name);

  constructor(
    private readonly support: SupportService,
    private readonly config: ConfigService,
  ) {}

  @Post('inbound-email')
  @HttpCode(HttpStatus.OK)
  @RateLimit('support:inbound')
  @Public('The Cloudflare Email Worker delivers support@/info@ mail here; every request must carry its HMAC signature.')
  async inbound(@Body() dto: InboundDeliveryDto) {
    const secret = this.config.get<string>('SUPPORT_INBOUND_SECRET')?.trim();
    if (!secret) throw new ServiceUnavailableException('Support email intake is not configured.');
    if (!verifyInbound(secret, dto.timestamp, dto.payload, dto.signature, Math.floor(Date.now() / 1000))) {
      this.logger.warn('[SUPPORT] inbound email refused: bad or stale signature');
      throw new UnauthorizedException('Bad signature.');
    }
    let email;
    try {
      email = parseInbound(JSON.parse(Buffer.from(dto.payload, 'base64').toString('utf8')));
    } catch {
      throw new BadRequestException('Unreadable email.');
    }
    return this.support.ingest(email);
  }
}
