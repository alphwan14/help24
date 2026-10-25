import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';
import { SupabaseService } from '../../supabase/supabase.service';
import { isAuthUuid } from './auth-identity';

/**
 * Linking a dashboard LOGIN (auth.users) to a Help24 PERSON (public.users).
 *
 * The link is the only thing that makes a dashboard login an admin's (the
 * middleware and restoreSession both resolve through user_auth_identities).
 * Until migration 122 it could only be made by hand-running SQL from the
 * runbook, and nothing told anyone a login was waiting — so a correctly
 * signed-in admin was turned away 53 times in one evening, unseen.
 *
 * Linking stays a HUMAN decision. A super admin picks the person; the link
 * records who (`linked_by`). An email match is never treated as proof: this
 * service never links anything it was not explicitly told to.
 *
 * Linking grants nothing by itself. The person still needs `role = 'admin'`
 * on their Help24 account, which is reported back so the dashboard can say so.
 */

export interface UnlinkedLogin {
  auth_subject: string;
  email: string | null;
  created_at: string;
  last_sign_in_at: string | null;
}

export interface LinkCandidate {
  id: string;
  name: string | null;
  email: string | null;
  phone_number: string | null;
  role: string;
  /** Already has a dashboard login linked — linking another would be refused. */
  has_dashboard_login: boolean;
}

export interface LinkResult {
  login_email: string;
  person_role: string;
  /** True only if the person can open the dashboard right now. */
  can_sign_in: boolean;
}

const REFUSALS: Record<string, () => Error> = {
  no_login: () => new NotFoundException('That dashboard login no longer exists.'),
  no_person: () => new NotFoundException('That Help24 account no longer exists.'),
  login_already_linked: () => new ConflictException('That login is already linked to a Help24 account.'),
  person_already_has_login: () =>
    new ConflictException('That person already has a dashboard login. Remove it before linking another.'),
  linked_by_required: () => new BadRequestException('The admin making the link must be recorded.'),
};

@Injectable()
export class AdminIdentityLinksService {
  private readonly logger = new Logger(AdminIdentityLinksService.name);

  constructor(private readonly supabase: SupabaseService) {}

  /** Dashboard logins nobody has linked, signed in or created in the last `days`. */
  async listUnlinked(days = 30): Promise<UnlinkedLogin[]> {
    const { data, error } = await this.supabase.client.rpc('admin_unlinked_dashboard_logins', { p_days: days });
    if (error) {
      this.logger.error(`[IDENTITY] unlinked-logins lookup failed: ${error.message}`);
      throw new ServiceUnavailableException('Could not read dashboard logins right now.');
    }
    return (data ?? []) as UnlinkedLogin[];
  }

  /**
   * Help24 people matching `query` by name, email or phone — the picker behind
   * "link this login" and "invite a person". Returns nothing for a query too
   * short to mean anything, rather than the whole user table.
   */
  async searchPeople(query: string): Promise<LinkCandidate[]> {
    // Characters that mean something to PostgREST's or() grammar or to LIKE are
    // dropped, so a query can only ever be a substring search.
    const q = query.replace(/[%_,()"\\*]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
    if (q.length < 2) return [];
    // Double-quoted because `.` and `:` are reserved inside or() values — an
    // email like "john.doe@…" would otherwise be misparsed. `"` was stripped
    // above, so the quotes cannot be closed from the input.
    const like = `"%${q}%"`;

    const { data: people, error } = await this.supabase.client
      .from('users')
      .select('id, name, email, phone_number, role')
      .or(`name.ilike.${like},email.ilike.${like},phone_number.ilike.${like}`)
      .order('name', { ascending: true })
      .limit(20);
    if (error) {
      this.logger.error(`[IDENTITY] people search failed: ${error.message}`);
      throw new ServiceUnavailableException('Could not search Help24 accounts right now.');
    }

    const ids = (people ?? []).map((p) => p.id as string);
    const linked = new Set<string>();
    if (ids.length > 0) {
      const { data: links, error: linkError } = await this.supabase.client
        .from('user_auth_identities')
        .select('help24_user_id')
        .eq('provider', 'supabase')
        .in('help24_user_id', ids);
      if (linkError) {
        this.logger.error(`[IDENTITY] link lookup failed: ${linkError.message}`);
        throw new ServiceUnavailableException('Could not search Help24 accounts right now.');
      }
      for (const l of links ?? []) linked.add(l.help24_user_id as string);
    }

    return (people ?? []).map((p) => ({
      id: p.id as string,
      name: (p.name as string | null) ?? null,
      email: (p.email as string | null) ?? null,
      phone_number: (p.phone_number as string | null) ?? null,
      role: (p.role as string | null) ?? 'user',
      has_dashboard_login: linked.has(p.id as string),
    }));
  }

  /** Link one dashboard login to one Help24 person, recording who decided it. */
  async link(authSubject: string, help24UserId: string, linkedBy: string): Promise<LinkResult> {
    if (!isAuthUuid(authSubject)) throw new BadRequestException('Not a dashboard login id.');
    if (!help24UserId.trim()) throw new BadRequestException('Choose a Help24 account.');

    const { data, error } = await this.supabase.client.rpc('admin_link_dashboard_login', {
      p_auth_subject: authSubject,
      p_help24_user_id: help24UserId,
      p_linked_by: linkedBy,
    });
    if (error) {
      this.logger.error(`[IDENTITY] link failed: ${error.message}`);
      throw new ServiceUnavailableException('Could not link that login right now.');
    }

    const result = (data ?? {}) as { outcome?: string; login_email?: string; person_role?: string };
    if (result.outcome !== 'linked') {
      throw (REFUSALS[result.outcome ?? ''] ?? (() => new ServiceUnavailableException('Could not link that login.')))();
    }

    const personRole = result.person_role ?? 'user';
    this.logger.log(`[IDENTITY] linked dashboard login ${authSubject.slice(0, 8)}… by ${linkedBy} (person role=${personRole})`);
    return {
      login_email: result.login_email ?? '',
      person_role: personRole,
      can_sign_in: personRole === 'admin',
    };
  }
}
