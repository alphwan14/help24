import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
  OnModuleInit,
  UnauthorizedException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash, randomBytes } from 'crypto';
import { SupabaseService } from '../../supabase/supabase.service';
import { ADMIN_ROLES, AdminContext, AdminRole } from './admin-role';

/** Plaintext bootstrap token seeded by migrations 045/052. */
const BOOTSTRAP_TOKEN = 'help24-super-admin-CHANGE-ME';

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
   *   3. Whether the bootstrap token RESOLVES in THIS project.
   *
   * If the bootstrap token does not resolve, auth cannot work for anyone — and
   * the cause is environment drift (wrong project) or an unapplied migration,
   * not the token code. This makes that impossible to misdiagnose.
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
    const bootstrapHash = AdminAuthService.hashToken(BOOTSTRAP_TOKEN);

    this.logger.log(
      `[ADMIN_AUTH_SELFCHECK] supabase_project=${ref} bootstrap_hash=${bootstrapHash.slice(0, 12)}…`,
    );

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
      .select('email, role, active')
      .eq('token_hash', bootstrapHash)
      .maybeSingle();

    if (boot && boot.active === true) {
      this.logger.log(
        `[ADMIN_AUTH_SELFCHECK] ✓ bootstrap token RESOLVES → ${boot.email as string} ` +
          `(role=${boot.role as string}). Admin auth is wired correctly.`,
      );
    } else if (boot) {
      this.logger.error(
        `[ADMIN_AUTH_SELFCHECK] ✗ bootstrap row exists but active=${String(boot.active)} — run migration 052.`,
      );
    } else {
      this.logger.error(
        `[ADMIN_AUTH_SELFCHECK] ✗ BOOTSTRAP TOKEN NOT FOUND in project '${ref}' ` +
          `(expected hash=${bootstrapHash.slice(0, 12)}…). This backend is pointed at a ` +
          `Supabase project that has no matching admin row. Either SUPABASE_URL points at the ` +
          `WRONG project, or migrations 045/052 were applied to a DIFFERENT project than this one. ` +
          `Compare ref '${ref}' against the project where your SELECT showed the rows.`,
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

    const { data, error } = await this.supabase.client
      .from('admin_users')
      .select('id, email, name, role, active')
      .eq('token_hash', tokenHash)
      .maybeSingle();

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
   * back — a new token is minted and the hash rotated. Does NOT create a row:
   * a missing/inactive admin is a recovery case, surfaced as a typed reason.
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

    const { error } = await this.supabase.client
      .from('admin_users')
      .update({ token_hash: tokenHash, last_login_at: new Date().toISOString() })
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
   * INDEPENDENTLY verify the Supabase access-token (JWT) against GoTrue, derive
   * the email from the verified token, confirm that email is an admin in
   * public.users (the same source of truth as the dashboard gate), and only
   * then mint a fresh arbitration token for the matching active admin_users row.
   *
   * This is what makes login automatically re-hydrate arbitration access with
   * zero manual token handling — while remaining forge-proof.
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
    const email = data?.user?.email?.toLowerCase();
    if (error || !email) {
      throw new UnauthorizedException('Your session could not be verified.');
    }

    // 2. Confirm admin in public.users — same gate the dashboard middleware uses.
    const { data: urow } = await this.supabase.client
      .from('users')
      .select('role')
      .eq('email', email)
      .maybeSingle();
    if (!urow || urow.role !== 'admin') {
      throw new ForbiddenException('This account does not have admin access.');
    }

    // 3. Mint a fresh arbitration token for the active admin_users row.
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
    return { id, active: false };
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
