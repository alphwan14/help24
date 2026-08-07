import { Controller, Get, Headers, Query, Res } from '@nestjs/common';
import { Response } from 'express';
import { Public } from '../common/auth/auth.decorator';
import { RateLimit } from '../common/rate-limit/rate-limit.decorator';
import { AppConfigService } from './app-config.service';

/**
 * The client bootstrap configuration endpoint.
 *
 * Public because it must be readable before sign-in: kill switches, the
 * maintenance banner and the minimum-version gate are exactly the things a
 * signed-out (or broken) client needs to know first. It serves only the
 * allowlisted `ClientConfig` projection — the service builds the response
 * from the typed contract, so nothing else in `app_settings` can leak.
 *
 * `platform` and `app_version` are accepted and logged, not acted on: they
 * exist so the access log shows the client population's version distribution
 * (which is how "is anyone still below the soft gate?" gets answered), and so
 * per-version shaping has a contract-stable home if it is ever needed. Serving
 * identical config to everyone is a deliberate Phase 1 simplification.
 *
 * ETag: `version` is a deterministic hash of the merged payload, so
 * If-None-Match turns the steady-state poll (launch + resume, 15-min TTL
 * client-side) into a 304 with an empty body.
 */
@Controller()
export class AppConfigController {
  constructor(private readonly config: AppConfigService) {}

  @RateLimit('config:read')
  @Public('Bootstrap configuration — kill switches, maintenance and version gates must be readable before sign-in.')
  @Get('config')
  async getConfig(
    @Res({ passthrough: true }) res: Response,
    @Headers('if-none-match') ifNoneMatch?: string,
    // Logged via the access line's URL; declared so the contract is visible.
    @Query('platform') _platform?: string,
    @Query('app_version') _appVersion?: string,
  ) {
    const { version, config } = await this.config.clientConfig();
    const etag = `"${version}"`;
    res.setHeader('ETag', etag);
    // Clients cache for 15 min anyway; this lets intermediaries do the same.
    res.setHeader('Cache-Control', 'public, max-age=60');

    if (ifNoneMatch === etag) {
      res.status(304);
      return;
    }
    return { version, config };
  }
}
