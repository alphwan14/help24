import {
  Body,
  Controller,
  Get,
  Headers,
  HttpCode,
  HttpStatus,
  NotFoundException,
  Param,
  Post,
} from '@nestjs/common';
import { AdminInvitesService } from './auth/admin-invites.service';
import { AdminAuthService } from './auth/admin-auth.service';
import {
  AcceptInviteDto,
  RestoreSessionDto,
} from './disputes/dto/admin-invite.dto';

/**
 * PUBLIC invite endpoints — intentionally NOT guarded by AdminAuthGuard.
 * Authorization is the single-use invite token itself. Separate controller
 * (same /admin prefix) so the guarded AdminUsersController stays fully locked.
 */
@Controller('admin')
export class AdminInvitesPublicController {
  constructor(
    private readonly invites: AdminInvitesService,
    private readonly auth: AdminAuthService,
  ) {}

  /**
   * TEMP token diagnostic — gated behind ADMIN_AUTH_DEBUG=1 (404 otherwise).
   * Hits the exact same header → authenticate() path as the guard and returns
   * the precise outcome (db_error / not_found / inactive / ok) WITHOUT leaking
   * the token or its full hash. Remove once the auth issue is resolved.
   *
   *   curl -H "Authorization: Bearer <token>" https://<api>/admin/_diag
   */
  @Get('_diag')
  async diag(@Headers('authorization') authHeader?: string) {
    if (
      process.env.ADMIN_AUTH_DEBUG !== '1' &&
      process.env.ADMIN_AUTH_DEBUG !== 'true'
    ) {
      // Hidden unless explicitly enabled.
      throw new NotFoundException();
    }

    const hasBearer = !!authHeader && authHeader.startsWith('Bearer ');
    const token = hasBearer ? authHeader!.slice(7).trim() : '';
    if (!token) {
      return {
        received: false,
        hint: 'Send "Authorization: Bearer <token>".',
      };
    }

    const result = await this.auth.authenticate(token);
    return {
      received: true,
      tokenLength: token.length,
      hashPrefix: AdminAuthService.hashToken(token).slice(0, 12),
      outcome: result.ok ? 'ok' : (result.reason ?? 'not_found'),
      detail: result.detail,
      email: result.admin?.email,
      role: result.admin?.role,
    };
  }

  /** Validate an invite token and return its metadata (email, role, expiry). */
  @Get('invite/:token')
  getInvite(@Param('token') token: string) {
    return this.invites.getInvite(token);
  }

  /**
   * Accept an invite. Provisions the full admin identity and returns the
   * one-time arbitration bearer token.
   */
  @Post('accept-invite')
  @HttpCode(HttpStatus.CREATED)
  async accept(@Body() dto: AcceptInviteDto) {
    const result = await this.invites.acceptInvite({
      token: dto.token,
      name: dto.name,
      password: dto.password,
    });
    return {
      ...result,
      notice:
        'Store this token now — it is shown only once and cannot be recovered. ' +
        'You can sign in to the dashboard with your email and the password you just set.',
    };
  }

  /**
   * Restore arbitration access from an authenticated Supabase session.
   *
   * PUBLIC by route, but NOT unauthenticated: the body carries the Supabase
   * access-token (JWT), which the backend verifies independently before issuing
   * a token. This is what lets a normal dashboard login silently re-hydrate
   * arbitration access — no manual token handling, no reconnect prompts.
   *
   * Returns the connected identity + a fresh one-time token (the dashboard
   * stores it in the httpOnly cookie server-side; it never reaches client JS).
   * 401 = session unverifiable, 403 = not an admin / inactive, 404 = no admin
   * record — these are the genuine recovery cases.
   */
  @Post('session/restore')
  @HttpCode(HttpStatus.OK)
  async restore(@Body() dto: RestoreSessionDto) {
    const r = await this.auth.restoreSession(dto.accessToken);
    return { email: r.email, name: r.name, role: r.role, token: r.token };
  }
}
