import {
  BadRequestException,
  ConflictException,
  GoneException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminAuthService } from './admin-auth.service';
import { AdminRole } from './admin-role';
import { assertAuthUuid } from './auth-identity';

const INVITE_TTL_DAYS = 7;

/** Non-terminal states — an invite is "active" (consumable, blocks duplicates)
 *  while pending or validated. completed/expired are terminal. */
const ACTIVE_STATUSES = ['pending', 'validated'] as const;

// 'accepted' is the legacy terminal value (pre-053); treated as 'completed'.
export type InviteStatus =
  | 'pending'
  | 'validated'
  | 'completed'
  | 'expired'
  | 'accepted';

export interface InviteMetadata {
  email: string;
  role: AdminRole;
  status: 'validated';
  expires_at: string;
}

/**
 * Invite-only admin onboarding.
 *
 * A super_admin issues an invite (email + role). The invitee accepts via a
 * single-use, 7-day link. On acceptance the FULL admin identity is provisioned
 * atomically across both auth layers:
 *
 *   1. Supabase Auth user (email + password)   → dashboard UI login
 *   2. public.users.role = 'admin'             → middleware access gate
 *   3. admin_users row + bearer token          → arbitration RBAC
 *
 * Single-use is enforced by atomically claiming the invite (pending → accepted)
 * BEFORE provisioning, so a double-submit can never create two admins.
 */
@Injectable()
export class AdminInvitesService {
  private readonly logger = new Logger(AdminInvitesService.name);
  private warnedNoDashboardUrl = false;

  constructor(
    private readonly supabase: SupabaseService,
    private readonly auth: AdminAuthService,
    private readonly config: ConfigService,
  ) {}

  /**
   * Base URL of the admin DASHBOARD (the Next.js frontend), where invite links
   * resolve to /accept-invite. This is the FRONTEND origin, never the backend —
   * a misconfig here is the classic "Cannot GET /admin/invite/:token" symptom.
   *   dev:  http://localhost:3001
   *   prod: https://help24-admin-dashboard.vercel.app
   */
  private get dashboardUrl(): string {
    const configured = this.config.get<string>('ADMIN_DASHBOARD_URL');
    if (!configured && !this.warnedNoDashboardUrl) {
      this.warnedNoDashboardUrl = true;
      this.logger.warn(
        '[INVITE] ADMIN_DASHBOARD_URL is not set — invite links default to ' +
          'https://help24-admin-dashboard.vercel.app. In dev set ADMIN_DASHBOARD_URL=http://localhost:3001 ' +
          'so links open the running dashboard, not production.',
      );
    }
    return (configured ?? 'https://help24-admin-dashboard.vercel.app').replace(/\/+$/, '');
  }

  // ── Create ─────────────────────────────────────────────────────────────────

  /** Issue an invite. super_admin only (enforced at the controller). */
  async createInvite(params: {
    email: string;
    role: AdminRole;
    createdBy: string;
  }): Promise<{ inviteLink: string; email: string; role: AdminRole; expires_at: string }> {
    const email = params.email.trim().toLowerCase();

    // Already a (live or deactivated) admin? Don't re-invite — manage instead.
    const { data: existingAdmin } = await this.supabase.client
      .from('admin_users')
      .select('id, active')
      .eq('email', email)
      .maybeSingle();
    if (existingAdmin) {
      throw new ConflictException(
        `${email} is already an admin. Manage their role from the admins list instead of re-inviting.`,
      );
    }

    // Lazy-expire any stale active invite so the partial unique index frees up
    // and re-inviting after expiry works.
    await this.expireStale(email);

    // Block duplicate ACTIVE invite (pending OR validated) — defense-in-depth on
    // top of the unique index.
    const { data: active } = await this.supabase.client
      .from('admin_invites')
      .select('id')
      .eq('email', email)
      .in('status', ACTIVE_STATUSES as unknown as string[])
      .maybeSingle();
    if (active) {
      throw new ConflictException(
        `An active invite already exists for ${email}. Revoke it before issuing a new one.`,
      );
    }

    const token = AdminAuthService.generateToken();
    const expiresAt = new Date(
      Date.now() + INVITE_TTL_DAYS * 24 * 60 * 60 * 1000,
    ).toISOString();

    const { error } = await this.supabase.client.from('admin_invites').insert({
      email,
      role: params.role,
      token,
      status: 'pending',
      created_by: params.createdBy,
      expires_at: expiresAt,
    });
    if (error) {
      // Unique-violation race on the partial index → treat as duplicate.
      if (error.code === '23505') {
        throw new ConflictException(
          `An active invite already exists for ${email}.`,
        );
      }
      throw new Error(error.message);
    }

    const inviteLink = `${this.dashboardUrl}/accept-invite?token=${token}`;
    this.logger.log(
      `[INVITE] created for ${email} (${params.role}) → ${this.dashboardUrl}/accept-invite`,
    );

    return { inviteLink, email, role: params.role, expires_at: expiresAt };
  }

  // ── Read / validate ──────────────────────────────────────────────────────

  /**
   * Public validation (GET). NON-consuming: it never marks the token used. It
   * only promotes pending → validated so we can tell "opened" from "untouched".
   * Safe to call repeatedly (open / refresh).
   */
  async getInvite(token: string): Promise<InviteMetadata> {
    const invite = await this.findByToken(token);
    if (!invite) throw new NotFoundException('Invite not found.');

    if (invite.status === 'completed' || invite.status === 'accepted') {
      throw new GoneException('This invitation has already been completed.');
    }
    if (this.isExpired(invite)) {
      await this.markExpired(invite);
      throw new GoneException('This invitation has expired.');
    }

    // pending/validated + not expired → mark validated (non-consuming).
    if (invite.status === 'pending') {
      await this.supabase.client
        .from('admin_invites')
        .update({ status: 'validated' })
        .eq('id', invite.id)
        .eq('status', 'pending');
    }

    return {
      email: invite.email,
      role: invite.role,
      status: 'validated',
      expires_at: invite.expires_at,
    };
  }

  // ── Accept ───────────────────────────────────────────────────────────────

  /**
   * Accept an invite. The token is consumed ONLY after the ENTIRE onboarding
   * succeeds (Stripe-style). Order is deliberate:
   *
   *   1. validate (do NOT consume)
   *   2. provision Supabase Auth user + password        ─┐ all idempotent, so a
   *   3. set public.users role by email                  │ retry of the SAME token
   *   4. create/rotate admin_users + bearer token        ─┘ before completion is safe
   *   5. ONLY NOW flip status → completed (terminal)
   *
   * A failure in 2–4 leaves the invite active (pending/validated) → the user can
   * safely refresh and retry. A completed invite returns 410.
   */
  async acceptInvite(params: {
    token: string;
    name: string;
    password: string;
  }): Promise<{ email: string; role: AdminRole; token: string }> {
    const name = params.name.trim();
    if (name.length < 2) {
      throw new BadRequestException('Please provide your full name.');
    }
    if (!params.password || params.password.length < 8) {
      throw new BadRequestException('Password must be at least 8 characters.');
    }

    // 1. Validate WITHOUT consuming.
    const invite = await this.findByToken(params.token);
    if (!invite) {
      throw new GoneException('This invitation is invalid.');
    }
    if (invite.status === 'completed' || invite.status === 'accepted') {
      throw new GoneException('This invitation has already been completed.');
    }
    if (this.isExpired(invite)) {
      await this.markExpired(invite);
      throw new GoneException('This invitation has expired.');
    }

    const email = invite.email.toLowerCase();
    const role = invite.role;

    // 2. Supabase Auth login (idempotent: create, or reset password if exists).
    const authUserId = await this.ensureAuthUser(email, params.password);

    // 3. Mark them an admin in public.users (by EMAIL, never overwriting id).
    await this.ensureAdminRole(email, authUserId);

    // 4. Arbitration RBAC identity + one-time bearer (idempotent on retry).
    const admin = await this.auth.createOrRotateAdmin({ email, name, role });

    // 5. EVERYTHING succeeded → consume the invite now (terminal). Conditional
    //    so a concurrent completion can't double-flip; either way the admin
    //    exists and we return a working token.
    await this.supabase.client
      .from('admin_invites')
      .update({ status: 'completed', accepted_at: new Date().toISOString() })
      .eq('id', invite.id)
      .in('status', ACTIVE_STATUSES as unknown as string[]);

    this.logger.log(`[INVITE] completed by ${email} as ${role}`);
    return { email, role, token: admin.token };
  }

  // ── Management helpers ─────────────────────────────────────────────────────

  /** List active (pending or validated) invites (super_admin only). */
  async listPending() {
    await this.expireAllStale();
    const { data } = await this.supabase.client
      .from('admin_invites')
      .select('id, email, role, status, created_at, expires_at')
      .in('status', ACTIVE_STATUSES as unknown as string[])
      .order('created_at', { ascending: false });
    return data ?? [];
  }

  /** Revoke an active (pending/validated) invite (super_admin only). */
  async revokeInvite(id: string) {
    const { data, error } = await this.supabase.client
      .from('admin_invites')
      .update({ status: 'expired' })
      .eq('id', id)
      .in('status', ACTIVE_STATUSES as unknown as string[])
      .select('id')
      .maybeSingle();
    if (error) throw new Error(error.message);
    if (!data) throw new NotFoundException('No active invite with that id.');
    return { id, revoked: true };
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private isExpired(invite: { status: InviteStatus; expires_at: string }): boolean {
    return (
      invite.status === 'expired' ||
      new Date(invite.expires_at).getTime() < Date.now()
    );
  }

  private async markExpired(invite: { id: string; status: InviteStatus }) {
    if (invite.status === 'expired') return;
    await this.supabase.client
      .from('admin_invites')
      .update({ status: 'expired' })
      .eq('id', invite.id);
  }

  private async findByToken(token: string) {
    const { data } = await this.supabase.client
      .from('admin_invites')
      .select('id, email, role, status, expires_at')
      .eq('token', token)
      .maybeSingle();
    return data as
      | {
          id: string;
          email: string;
          role: AdminRole;
          status: InviteStatus;
          expires_at: string;
        }
      | null;
  }

  private async expireStale(email: string) {
    await this.supabase.client
      .from('admin_invites')
      .update({ status: 'expired' })
      .eq('email', email)
      .in('status', ACTIVE_STATUSES as unknown as string[])
      .lt('expires_at', new Date().toISOString());
  }

  private async expireAllStale() {
    await this.supabase.client
      .from('admin_invites')
      .update({ status: 'expired' })
      .in('status', ACTIVE_STATUSES as unknown as string[])
      .lt('expires_at', new Date().toISOString());
  }

  /**
   * Set role='admin' on the public.users row for this email. If a row already
   * exists (an existing Firebase app user being promoted), UPDATE by email and
   * KEEP its Firebase-UID primary key. Only when no row exists do we insert a
   * new one — and the id there is just a unique TEXT key (we reuse the auth
   * UUID string), since the middleware never reads users.id.
   */
  private async ensureAdminRole(
    email: string,
    newRowId: string,
  ): Promise<void> {
    const { data: existing, error: selErr } = await this.supabase.client
      .from('users')
      .select('id')
      .eq('email', email)
      .maybeSingle();

    if (selErr) {
      this.logger.error(`[INVITE] users lookup failed for ${email}: ${selErr.message}`);
    }

    if (existing) {
      const { error } = await this.supabase.client
        .from('users')
        .update({ role: 'admin' })
        .eq('email', email);
      if (error) {
        this.logger.error(`[INVITE] users role update failed for ${email}: ${error.message}`);
      }
      return;
    }

    const { error } = await this.supabase.client
      .from('users')
      .insert({ id: newRowId, email, role: 'admin' });
    if (error) {
      this.logger.error(`[INVITE] users insert failed for ${email}: ${error.message}`);
    }
  }

  /**
   * Find a Supabase AUTH user's UUID by email via the admin API (paginated).
   * Critically: this returns the auth.users UUID, NOT public.users.id.
   */
  private async findAuthUserIdByEmail(email: string): Promise<string | null> {
    const target = email.toLowerCase();
    for (let page = 1; page <= 20; page++) {
      const { data, error } = await this.supabase.client.auth.admin.listUsers({
        page,
        perPage: 200,
      });
      if (error) {
        this.logger.error(`[INVITE] listUsers failed: ${error.message}`);
        return null;
      }
      const users = data?.users ?? [];
      const found = users.find(
        (u) => (u.email ?? '').toLowerCase() === target,
      );
      if (found?.id) return found.id;
      if (users.length < 200) break; // last page
    }
    return null;
  }

  /**
   * Create the Supabase Auth user, or — if the email is already registered in
   * Supabase Auth — resolve that auth user's UUID by email and reset its
   * password. NEVER uses public.users.id (a Firebase UID), which is what caused
   * the "Expected parameter to be UUID" crash.
   */
  private async ensureAuthUser(
    email: string,
    password: string,
  ): Promise<string> {
    const { data: created, error } =
      await this.supabase.client.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
      });

    if (!error && created?.user?.id) {
      // Guard the Supabase response id before any downstream auth use.
      return assertAuthUuid(created.user.id, 'invite acceptance (createUser)');
    }

    // Already registered in Supabase Auth → resolve the AUTH UUID by email and
    // reset the password. (Do NOT fall back to public.users.id.)
    const authId = await this.findAuthUserIdByEmail(email);
    if (authId) {
      assertAuthUuid(authId, 'invite acceptance (updateUserById)');
      const { error: updErr } =
        await this.supabase.client.auth.admin.updateUserById(authId, {
          password,
        });
      if (updErr) {
        this.logger.error(`[INVITE] updateUserById failed for ${email}: ${updErr.message}`);
        throw new BadRequestException(
          'Could not set your password. Contact a super_admin.',
        );
      }
      return authId;
    }

    this.logger.error(
      `[INVITE] could not provision auth user for ${email}: ${error?.message ?? 'unknown'}`,
    );
    throw new BadRequestException(
      'Could not create your login. Contact a super_admin.',
    );
  }
}
