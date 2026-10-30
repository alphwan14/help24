import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
  OnModuleInit,
  ServiceUnavailableException,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, randomBytes } from 'crypto';
import { SupabaseService } from '../../supabase/supabase.service';
import { ADMIN_ROLES, AdminContext, AdminRole } from './admin-role';

/**
 * Plaintext of the RETIRED bootstrap token that migrations 045/052 once seeded.
 * The account itself was deleted by migration 111. The constant is kept only so
 * the startup self-check can detect the row ever reappearing — its value is in
 * a public repository, so a matching row is a super_admin anyone can use.
 */
const RETIRED_BOOTSTRAP_TOKEN = 'help24-super-admin-CHANGE-ME';

/**
 * Lifetime of a console key in admin_sessions (migration 133) — the same as
 * the dashboard's h24_admin_token cookie, which renews it from the Supabase
 * session.
 */
const SESSION_TTL_MS = 12 * 60 * 60 * 1000;

/** PostgREST / Postgres "no such table": admin_sessions before 133 is applied. */
function isMissingTable(error: { code?: string }): boolean {
  return error.code === 'PGRST205' || error.code === '42P01';
}

// =============================================================================
// RULE — IDENTITY STANDARDIZATION (applies to this whole auth module)
//   Supabase Auth (auth.users.id, UUID) = ONLY valid identity for authentication
//   public.users.id (Firebase UID, TEXT) = application metadata ONLY
//   NEVER MIX. Any value reaching auth.admin.* must pass assertAuthUuid()
//   (see ./auth-identity.ts). admin_users uses its own UUID for RBAC; role
//   provisioning in public.users is keyed by EMAIL, never by id.
// =============================================================================

/**
 * Outcome of a token authentication attempt. Distinguishing these is critical:
 * a swallowed DB error (schema drift, PostgREST cache, wrong project) must NOT
 * masquerade as a bad token, or auth bugs become undebuggable.
 */
export type TokenAuthReason = 'db_error' | 'not_found' | 'inactive';
export interface TokenAuthResult {
  ok: boolean;
  admin?: AdminContext;
  reason?: TokenAuthReason;
  detail?: string;
}

/**
 * Resolves bearer tokens to admin identities and manages admin_users.
 *
 * Tokens are opaque random strings. Only the SHA-256 hash is stored, so a DB
 * leak does not expose usable credentials. Lookup hashes the incoming token and
 * matches on token_hash (indexed). This is the ONLY admin auth mechanism — no
 * Supabase Auth / JWT / Firebase involvement.
 */
@Injectable()
export class AdminAuthService implements OnModuleInit {
  private readonly logger = new Logger(AdminAuthService.name);
  /** TEMP debug: set ADMIN_AUTH_DEBUG=1 to log every token resolution. */
  private readonly debug =
    process.env.ADMIN_AUTH_DEBUG === '1' ||
    process.env.ADMIN_AUTH_DEBUG === 'true';

  constructor(
    private readonly supabase: SupabaseService,
    private readonly config: ConfigService,
  ) {}

  /**
   * Startup self-check — runs once at boot and ALWAYS logs (cannot be missed in
   * deploy logs). Proves three things at a glance:
   *   1. WHICH Supabase project this backend is actually talking to (ref).
   *   2. Whether admin_users is readable here (and how many rows).
   *   3. That at least one active admin exists, and that the retired public
   *      bootstrap token (removed in migration 111) has not reappeared.
   */
  async onModuleInit(): Promise<void> {
    try {
      await this.selfCheck();
    } catch (e) {
      this.logger.error(
        `[ADMIN_AUTH_SELFCHECK] crashed: ${(e as Error).message}`,
      );
    }
  }

  private projectRef(url: string): string {
    try {
      return new URL(url).hostname.split('.')[0];
    } catch {
      return 'unknown';
    }
  }

  private async selfCheck(): Promise<void> {
    const url = this.config.get<string>('SUPABASE_URL') ?? '';
    const ref = this.projectRef(url);
    const retiredHash = AdminAuthService.hashToken(RETIRED_BOOTSTRAP_TOKEN);

    this.logger.log(`[ADMIN_AUTH_SELFCHECK] supabase_project=${ref}`);

    const { data, error, count } = await this.supabase.client
      .from('admin_users')
      .select('email', { count: 'exact' });

    if (error) {
      this.logger.error(
        `[ADMIN_AUTH_SELFCHECK] ✗ cannot read admin_users (code=${error.code ?? '?'}): ${error.message} ` +
          `— schema/cache/permissions problem in project '${ref}'.`,
      );
      return;
    }

    this.logger.log(
      `[ADMIN_AUTH_SELFCHECK] admin_users rows=${count ?? data?.length ?? 0} in project '${ref}'`,
    );

    const { data: boot } = await this.supabase.client
      .from('admin_users')
      .select('email, active')
      .eq('token_hash', retiredHash)
      .maybeSingle();

    if (boot) {
      // Tripwire: this row was deleted by migration 111 and its plaintext is in
      // a public repository, so a matching row is a super_admin whose password
      // everyone has. It reappearing means 045/052 were replayed somewhere.
      this.logger.error(
        `[ADMIN_AUTH_SELFCHECK] ✗ a row matching the RETIRED public bootstrap token exists ` +
          `(${boot.email as string}, active=${String(boot.active)}) in project '${ref}'. ` +
          `Migration 111 deleted this account and nothing may recreate it. Delete it again:\n` +
          `    DELETE FROM public.admin_users WHERE token_hash = '${retiredHash}';`,
      );
    }

    const { count: activeAdmins } = await this.supabase.client
      .from('admin_users')
      .select('email', { count: 'exact', head: true })
      .eq('active', true)
      .neq('token_hash', retiredHash);

    const activeAdminCount = activeAdmins ?? 0;

    if (activeAdminCount > 0) {
      this.logger.log(
        `[ADMIN_AUTH_SELFCHECK] ✓ ${activeAdminCount} active admin(s) in project '${ref}'` +
          (boot ? '.' : '. No bootstrap account exists — fully hardened.'),
      );
    } else {
      this.logger.error(
        `[ADMIN_AUTH_SELFCHECK] ✗ NO ADMIN CAN SIGN IN to project '${ref}' — no active admins. ` +
          `Either SUPABASE_URL points at the WRONG project, or every account was deactivated. ` +
          `Re-enable one directly in the database:\n` +
          `    UPDATE public.admin_users SET active = TRUE WHERE email = '<your-admin-email>';`,
      );
    }
  }

  static hashToken(token: string): string {
    return createHash('sha256').update(token.trim()).digest('hex');
  }

  /**
   * Cryptographically secure, URL-safe bearer/invite token.
   * 32 random bytes → 43-char base64url string. Use for every admin secret.
   */
  static generateToken(): string {
    return randomBytes(32).toString('base64url');
  }

  /**
   * Authenticate a bearer token, returning a DISCRIMINATED result so callers
   * can respond correctly to each failure mode (and so logs pinpoint the cause):
   *
   *   db_error  → the SELECT itself failed (schema/cache/connection). NOT a bad
   *               token. Surfaces as 503, never a silent 401.
   *   not_found → no admin_users row has this token's hash (wrong token, wrong
   *               environment/project, or unapplied seed).
   *   inactive  → the row exists but active = false (deactivated admin).
   */
  async authenticate(rawToken: string): Promise<TokenAuthResult> {
    const token = rawToken.trim();
    const tokenHash = AdminAuthService.hashToken(token);

    if (this.debug) {
      this.logger.debug(
        `[ADMIN_AUTH] lookup token="${token.slice(0, 6)}…"(len=${token.length}) hash=${tokenHash.slice(0, 12)}…`,
      );
    }

    // A per-sign-in key (migration 133) — what every restore issues — names
    // its admin; otherwise the token may be the admin row's own key (an
    // invite just accepted, or the backend before 133). Either way the admin
    // row below is read fresh, so active and role are never taken from a key.
    const session = await this.findSession(tokenHash);
    if (session.error) {
      this.logger.error(`[ADMIN_AUTH] session lookup FAILED: ${session.error}`);
      return { ok: false, reason: 'db_error', detail: session.error };
    }

    const lookup = this.supabase.client
      .from('admin_users')
      .select('id, email, name, role, active');
    const { data, error } = await (session.adminId
      ? lookup.eq('id', session.adminId)
      : lookup.eq('token_hash', tokenHash)
    ).maybeSingle();

    if (error) {
      // e.g. code 42703 = undefined_column (schema drift), PGRST = cache stale.
      this.logger.error(
        `[ADMIN_AUTH] DB lookup FAILED (code=${error.code ?? '?'}): ${error.message} ` +
          `— this is a backend/schema problem, not a bad token.`,
      );
      return { ok: false, reason: 'db_error', detail: error.message };
    }

    if (!data) {
      if (this.debug) {
        this.logger.warn(
          `[ADMIN_AUTH] NO MATCH for hash=${tokenHash.slice(0, 12)}… ` +
            `— token unknown, or pointing at the wrong Supabase project.`,
        );
      }
      return { ok: false, reason: 'not_found' };
    }

    if (data.active !== true) {
      this.logger.warn(`[ADMIN_AUTH] admin ${data.email as string} is INACTIVE`);
      return { ok: false, reason: 'inactive' };
    }

    // Best-effort last-seen stamp; never blocks the request.
    void this.supabase.client
      .from('admin_users')
      .update({ last_login_at: new Date().toISOString() })
      .eq('id', data.id as string);

    if (this.debug) {
      this.logger.debug(
        `[ADMIN_AUTH] ✓ resolved ${data.email as string} (role=${data.role as string})`,
      );
    }

    return {
      ok: true,
      admin: {
        id: data.id as string,
        email: data.email as string,
        name: (data.name as string) ?? '',
        role: data.role as AdminRole,
      },
    };
  }

  /**
   * The admin a live per-sign-in key belongs to. An unknown or expired key —
   * or no admin_sessions table yet — is simply no match; only a failed
   * lookup is an error.
   */
  private async findSession(tokenHash: string): Promise<{ adminId?: string; error?: string }> {
    const { data, error } = await this.supabase.client
      .from('admin_sessions')
      .select('admin_id, expires_at')
      .eq('token_hash', tokenHash)
      .maybeSingle();
    if (error) return isMissingTable(error) ? {} : { error: error.message };
    if (!data || new Date(data.expires_at as string).getTime() <= Date.now()) return {};
    return { adminId: data.admin_id as string };
  }

  /**
   * Record a new console key for this admin, beside any other device's.
   * False when admin_sessions does not exist yet (before migration 133): the
   * caller then falls back to the admin row's single key.
   */
  private async issueSession(adminId: string, tokenHash: string): Promise<boolean> {
    const now = Date.now();
    const { error } = await this.supabase.client.from('admin_sessions').insert({
      token_hash: tokenHash,
      admin_id: adminId,
      expires_at: new Date(now + SESSION_TTL_MS).toISOString(),
    });
    if (error) {
      if (isMissingTable(error)) return false;
      throw new Error(error.message);
    }
    // Housekeeping, best effort: an expired key can never authenticate.
    this.supabase.client
      .from('admin_sessions')
      .delete()
      .lt('expires_at', new Date(now).toISOString())
      .then(
        () => undefined,
        () => undefined,
      );
    return true;
  }

  /** Back-compat convenience: AdminContext or null (loses the failure reason). */
  async resolveToken(token: string): Promise<AdminContext | null> {
    const result = await this.authenticate(token);
    return result.ok && result.admin ? result.admin : null;
  }

  /**
   * Create a new admin_users row with a fresh bearer token. Returns the
   * plaintext token ONCE — only its hash is stored, so it cannot be recovered.
   * Used directly by POST /admin/admins and by the invite-acceptance flow.
   */
  async createAdmin(params: {
    email: string;
    name: string;
    role: AdminRole;
  }): Promise<{ id: string; email: string; role: AdminRole; token: string }> {
    const email = params.email.trim().toLowerCase();

    const { data: existing } = await this.supabase.client
      .from('admin_users')
      .select('id')
      .eq('email', email)
      .maybeSingle();
    if (existing) {
      throw new ConflictException(`An admin already exists for ${email}.`);
    }

    const token = AdminAuthService.generateToken();
    const tokenHash = AdminAuthService.hashToken(token);

    if (this.debug) {
      // Proof of no truncation: this stored-hash prefix MUST equal the hashPrefix
      // that GET /admin/_diag reports for the same returned token.
      this.logger.debug(
        `[ADMIN_AUTH] createAdmin email=${email} token_len=${token.length} ` +
          `stored_hash=${tokenHash.slice(0, 12)}…`,
      );
    }

    const { data, error } = await this.supabase.client
      .from('admin_users')
      .insert({
        email,
        name: params.name,
        role: params.role,
        token_hash: tokenHash,
      })
      .select('id, email, role')
      .single();

    if (error || !data) {
      throw new Error(error?.message ?? 'Failed to create admin');
    }

    return {
      id: data.id as string,
      email: data.email as string,
      role: data.role as AdminRole,
      token,
    };
  }

  /**
   * Idempotent, retry-safe admin provisioning for the invite flow. Unlike
   * createAdmin (which throws on a duplicate), this CREATES the admin_users row
   * or — if one already exists for the email (a prior partial/retried accept) —
   * ROTATES its token and re-activates it. Always returns a working one-time
   * token, so refreshing/retrying an unfinished invite never gets stuck.
   */
  async createOrRotateAdmin(params: {
    email: string;
    name: string;
    role: AdminRole;
  }): Promise<{ id: string; email: string; role: AdminRole; token: string }> {
    const email = params.email.trim().toLowerCase();
    const token = AdminAuthService.generateToken();
    const tokenHash = AdminAuthService.hashToken(token);

    const { data: existing } = await this.supabase.client
      .from('admin_users')
      .select('id')
      .eq('email', email)
      .maybeSingle();

    if (existing) {
      const { error } = await this.supabase.client
        .from('admin_users')
        .update({ token_hash: tokenHash, name: params.name, role: params.role, active: true })
        .eq('id', existing.id as string);
      if (error) throw new Error(error.message);
      return { id: existing.id as string, email, role: params.role, token };
    }

    const { data, error } = await this.supabase.client
      .from('admin_users')
      .insert({ email, name: params.name, role: params.role, token_hash: tokenHash })
      .select('id')
      .single();

    if (error || !data) {
      // Lost an insert race → an admin row now exists; rotate it instead.
      if (error?.code === '23505') {
        const { data: raced } = await this.supabase.client
          .from('admin_users')
          .select('id')
          .eq('email', email)
          .maybeSingle();
        if (raced) {
          await this.supabase.client
            .from('admin_users')
            .update({ token_hash: tokenHash, name: params.name, role: params.role, active: true })
            .eq('id', raced.id as string);
          return { id: raced.id as string, email, role: params.role, token };
        }
      }
      throw new Error(error?.message ?? 'Failed to provision admin');
    }

    return { id: data.id as string, email, role: params.role, token };
  }

  /**
   * Re-issue a bearer token for an EXISTING, ACTIVE admin identified by email.
   * The caller MUST have already verified the Supabase session for this email
   * (see restoreSession) — possession of a valid session is authorization-
   * equivalent to a fresh login, so no token/password is required here.
   *
   * Only the token HASH is stored, so the previous plaintext cannot be handed
   * back — a new token is minted. Since migration 133 it is a key of its own
   * in admin_sessions, so the keys this admin's other devices hold keep
   * working; the admin row's single key is retired (nobody should be holding
   * it once restores issue sessions). Before 133 the row's key is rotated, as
   * it always was. Does NOT create a row: a missing/inactive admin is a
   * recovery case, surfaced as a typed reason.
   */
  async reissueTokenForAdmin(email: string): Promise<{
    ok: boolean;
    reason?: 'not_found' | 'inactive';
    id?: string;
    email?: string;
    name?: string;
    role?: AdminRole;
    token?: string;
  }> {
    const normalized = email.trim().toLowerCase();

    const { data } = await this.supabase.client
      .from('admin_users')
      .select('id, email, name, role, active')
      .eq('email', normalized)
      .maybeSingle();

    if (!data) return { ok: false, reason: 'not_found' };
    if (data.active !== true) return { ok: false, reason: 'inactive' };

    const token = AdminAuthService.generateToken();
    const tokenHash = AdminAuthService.hashToken(token);
    const issued = await this.issueSession(data.id as string, tokenHash);

    const { error } = await this.supabase.client
      .from('admin_users')
      .update({
        token_hash: issued
          ? AdminAuthService.hashToken(AdminAuthService.generateToken())
          : tokenHash,
        last_login_at: new Date().toISOString(),
      })
      .eq('id', data.id as string);
    if (error) throw new Error(error.message);

    return {
      ok: true,
      id: data.id as string,
      email: data.email as string,
      name: (data.name as string) ?? '',
      role: data.role as AdminRole,
      token,
    };
  }

  /**
   * Restore an arbitration session from an authenticated Supabase session.
   *
   * Trust model: the dashboard cannot be trusted to assert "I am X". Instead we
   * INDEPENDENTLY verify the Supabase access-token (JWT) against GoTrue, then
   * resolve the verified credential to a Help24 person through
   * `user_auth_identities` — the SAME gate the dashboard middleware uses
   * (admin-dashboard/lib/admin-identity.ts) — and only then mint a fresh
   * arbitration token for the matching active admin_users row.
   *
   * WHY NOT BY EMAIL
   * This used to look up `public.users` by the session's email. That made the
   * two gates disagree about who is an admin: an admin whose dashboard login
   * uses a different address from their app account passed the middleware once
   * linked, then failed here and sat on "Your session needs refreshing"
   * forever. The verified `user.id` is the credential; the link says which
   * person it belongs to; nothing user-writable takes part.
   *
   * Fails CLOSED at every step. A lookup that errors is a 503, never a "not an
   * admin" — the two mean different things to whoever is reading the log.
   */
  async restoreSession(accessToken: string): Promise<{
    id: string;
    email: string;
    name: string;
    role: AdminRole;
    token: string;
  }> {
    // 1. Verify the Supabase session JWT itself (not a claimed email).
    const { data, error } =
      await this.supabase.client.auth.getUser(accessToken);
    const authSubject = data?.user?.id;
    const email = data?.user?.email?.toLowerCase();
    if (error || !authSubject || !email) {
      throw new UnauthorizedException('Your session could not be verified.');
    }

    // 2. Which Help24 person is this credential? Through the link, never email.
    const { data: link, error: linkError } = await this.supabase.client
      .from('user_auth_identities')
      .select('help24_user_id')
      .eq('provider', 'supabase')
      .eq('subject', authSubject)
      .maybeSingle();
    if (linkError) {
      this.logger.error(`[ADMIN_AUTH] identity lookup failed: ${linkError.message}`);
      throw new ServiceUnavailableException('Could not verify admin access right now.');
    }
    if (!link) {
      throw new ForbiddenException('This login is not linked to a Help24 account yet.');
    }

    // 3. Is that person an admin? Same question the middleware asks.
    const { data: person, error: personError } = await this.supabase.client
      .from('users')
      .select('role')
      .eq('id', link.help24_user_id as string)
      .maybeSingle();
    if (personError) {
      this.logger.error(`[ADMIN_AUTH] role lookup failed: ${personError.message}`);
      throw new ServiceUnavailableException('Could not verify admin access right now.');
    }
    if (!person || person.role !== 'admin') {
      throw new ForbiddenException('This account does not have admin access.');
    }

    // 4. Mint a fresh arbitration token for the active admin_users row. That
    //    row belongs to the dashboard CREDENTIAL (it is what the invite was
    //    issued to), so it is keyed by the verified session email.
    const result = await this.reissueTokenForAdmin(email);
    if (!result.ok || !result.token) {
      if (result.reason === 'inactive') {
        throw new ForbiddenException('This admin account is inactive.');
      }
      throw new NotFoundException('No admin record found for this account.');
    }

    if (this.debug) {
      this.logger.debug(
        `[ADMIN_AUTH] session restored for ${email} (role=${result.role})`,
      );
    }

    return {
      id: result.id as string,
      email: result.email as string,
      name: result.name as string,
      role: result.role as AdminRole,
      token: result.token,
    };
  }

  async listAdmins() {
    const { data } = await this.supabase.client
      .from('admin_users')
      .select('id, email, name, role, active, created_at, last_login_at')
      .order('created_at', { ascending: false });
    return data ?? [];
  }

  /** Number of currently active super_admins — used to block lockout. */
  private async countActiveSuperAdmins(excludeId?: string): Promise<number> {
    let q = this.supabase.client
      .from('admin_users')
      .select('id', { count: 'exact', head: true })
      .eq('role', 'super_admin')
      .eq('active', true);
    if (excludeId) q = q.neq('id', excludeId);
    const { count } = await q;
    return count ?? 0;
  }

  /**
   * Change an admin's role (super_admin only). Refuses to demote the last
   * remaining super_admin, which would lock the org out of admin management.
   */
  async updateRole(id: string, role: AdminRole) {
    if (!ADMIN_ROLES.includes(role)) {
      throw new BadRequestException(`Unknown role '${role}'.`);
    }

    const target = await this.requireAdmin(id);

    if (target.role === 'super_admin' && role !== 'super_admin') {
      const others = await this.countActiveSuperAdmins(id);
      if (others === 0) {
        throw new BadRequestException(
          'Cannot demote the last active super_admin.',
        );
      }
    }

    const { data, error } = await this.supabase.client
      .from('admin_users')
      .update({ role })
      .eq('id', id)
      .select('id, email, name, role, active')
      .single();
    if (error || !data) throw new Error(error?.message ?? 'Failed to update role');
    return data;
  }

  /**
   * Soft-delete an admin (active = false). Refuses self-deactivation and
   * deactivating the last active super_admin. A deactivated admin's token stops
   * resolving immediately (resolveToken checks active).
   */
  async deactivateAdmin(id: string, actingAdminId: string) {
    if (id === actingAdminId) {
      throw new BadRequestException('You cannot deactivate your own account.');
    }

    const target = await this.requireAdmin(id);

    if (target.role === 'super_admin') {
      const others = await this.countActiveSuperAdmins(id);
      if (others === 0) {
        throw new BadRequestException(
          'Cannot deactivate the last active super_admin.',
        );
      }
    }

    const { error } = await this.supabase.client
      .from('admin_users')
      .update({ active: false })
      .eq('id', id);
    if (error) throw new Error(error.message);

    // Their keys already stop working (authenticate reads `active`); removing
    // them means re-enabling this admin later does not revive an old device.
    const { error: revokeError } = await this.supabase.client
      .from('admin_sessions')
      .delete()
      .eq('admin_id', id);
    if (revokeError && !isMissingTable(revokeError)) {
      this.logger.warn(`[ADMIN_AUTH] could not revoke sessions of ${id}: ${revokeError.message}`);
    }
    return { id, active: false };
  }

  /**
   * Undo a deactivation. Grants nothing by itself: the admin still needs a
   * fresh sign-in, and restoreSession still asks the identity link and the
   * person's role, so someone whose app account is no longer an admin stays
   * out. Their old keys were deleted on deactivation; none come back.
   */
  async reactivateAdmin(id: string) {
    const target = await this.requireAdmin(id);
    if (target.active) return { id, active: true };

    const { error } = await this.supabase.client
      .from('admin_users')
      .update({ active: true })
      .eq('id', id);
    if (error) throw new Error(error.message);
    this.logger.log(`[ADMIN_AUTH] reactivated ${target.email}`);
    return { id, active: true };
  }

  private async requireAdmin(id: string) {
    const { data } = await this.supabase.client
      .from('admin_users')
      .select('id, email, name, role, active')
      .eq('id', id)
      .maybeSingle();
    if (!data) throw new NotFoundException('Admin not found.');
    return data as {
      id: string;
      email: string;
      name: string;
      role: AdminRole;
      active: boolean;
    };
  }
}
