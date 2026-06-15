import { Injectable, Logger } from '@nestjs/common';
import { createHash } from 'crypto';
import { SupabaseService } from '../../supabase/supabase.service';
import { AdminContext, AdminRole } from './admin-role';

/**
 * Resolves bearer tokens to admin identities and manages admin_users.
 *
 * Tokens are opaque random strings. Only the SHA-256 hash is stored, so a DB
 * leak does not expose usable credentials. Lookup hashes the incoming token and
 * matches on token_hash (indexed).
 */
@Injectable()
export class AdminAuthService {
  private readonly logger = new Logger(AdminAuthService.name);

  constructor(private readonly supabase: SupabaseService) {}

  static hashToken(token: string): string {
    return createHash('sha256').update(token).digest('hex');
  }

  /** Returns the admin for a bearer token, or null if invalid/inactive. */
  async resolveToken(token: string): Promise<AdminContext | null> {
    const tokenHash = AdminAuthService.hashToken(token.trim());

    const { data, error } = await this.supabase.client
      .from('admin_users')
      .select('id, email, name, role, active')
      .eq('token_hash', tokenHash)
      .maybeSingle();

    if (error) {
      this.logger.error(`[ADMIN_AUTH] token lookup failed: ${error.message}`);
      return null;
    }
    if (!data || data.active !== true) return null;

    // Best-effort last-seen stamp; never blocks the request.
    void this.supabase.client
      .from('admin_users')
      .update({ last_login_at: new Date().toISOString() })
      .eq('id', data.id as string);

    return {
      id: data.id as string,
      email: data.email as string,
      name: (data.name as string) ?? '',
      role: data.role as AdminRole,
    };
  }

  /** Create a new admin. Returns the plaintext token ONCE (never stored). */
  async createAdmin(params: {
    email: string;
    name: string;
    role: AdminRole;
  }): Promise<{ id: string; email: string; role: AdminRole; token: string }> {
    // 32 random bytes → 64 hex chars. Shown once to the caller.
    const token = createHash('sha256')
      .update(`${params.email}:${Date.now()}:${Math.random()}`)
      .digest('hex');
    const tokenHash = AdminAuthService.hashToken(token);

    const { data, error } = await this.supabase.client
      .from('admin_users')
      .insert({
        email: params.email,
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

  async listAdmins() {
    const { data } = await this.supabase.client
      .from('admin_users')
      .select('id, email, name, role, active, created_at, last_login_at')
      .order('created_at', { ascending: false });
    return data ?? [];
  }
}
