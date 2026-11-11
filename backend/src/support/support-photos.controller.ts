import { Controller, Get, Param, ParseIntPipe, ParseUUIDPipe, Query, Res } from '@nestjs/common';
import type { Response } from 'express';
import { Public } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { SupportService } from './support.service';

/**
 * GET /support/photos/:messageId/:index?e=<expiry>&s=<signature>
 *
 * Message Help24 photos on Help24's own address (migration 143). The app and
 * the Inbox are given these links instead of storage-provider ones; each is
 * signed by the backend and expires within two hours. A wrong, expired or
 * tampered link is "not found".
 */
@Controller('support/photos')
export class SupportPhotosController {
  constructor(private readonly support: SupportService) {}

  @Get(':messageId/:index')
  @RateLimit('support:photos')
  @Public(
    'Photo links are opened by an <img> tag or the app image viewer, which cannot send a bearer token. ' +
      'Each link carries its own HMAC signature and expiry, checked before any byte is read.',
  )
  async photo(
    @Param('messageId', ParseUUIDPipe) messageId: string,
    @Param('index', ParseIntPipe) index: number,
    @Query('e') e: string,
    @Query('s') s: string,
    @Res() res: Response,
  ) {
    const { bytes, mime } = await this.support.photo(messageId, index, Number(e), String(s ?? ''));
    res.set({
      'Content-Type': mime,
      'Content-Length': String(bytes.length),
      // The link is the permission: keep it out of shared caches, let the
      // viewer's own browser reuse it until it expires.
      'Cache-Control': 'private, max-age=3600',
      'Content-Disposition': 'inline',
      'X-Content-Type-Options': 'nosniff',
      // The Inbox (admin.help24.co.ke) shows these in <img> tags.
      'Cross-Origin-Resource-Policy': 'cross-origin',
      'Content-Security-Policy': "default-src 'none'",
    });
    res.send(bytes);
  }
}
