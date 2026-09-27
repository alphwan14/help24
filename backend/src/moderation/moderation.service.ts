import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationPayload, NotificationsService } from '../notifications/notifications.service';
import { AdminContext, roleAtLeast } from '../admin/auth/admin-role';
import { RequestContextStore } from '../common/request-context/request-context';
import { AccountStateService } from './account-state.service';
import {
  ContentActionDto,
  LiftRestrictionDto,
  ResolveReportDto,
  SanctionDto,
  TriageReportDto,
} from './dto/moderation-admin.dto';
import { LIFT_MIN_ROLE, RestrictionKind, SANCTION_MIN_ROLE, SanctionKind } from './moderation.constants';
import { toHttpError } from './moderation-errors';

const DAY_MS = 86_400_000;

/**
 * Every moderation WRITE, and nothing else.
 *
 * Each method checks what the database cannot know — the admin RBAC ladder and
 * the assignment lock — then calls exactly one migration-115 function, which
 * performs the change AND writes its ledger row in one transaction. There is no
 * other write path: 114 revoked direct writes to the moderation tables even
 * from service_role, so this service could not bypass the ledger if it tried.
 *
 * Notifications go out after the database has committed, are best-effort, and
 * say only WHAT happened in general terms — never the reason (the person reads
 * that in the app, from my_account_status) and never who reported them.
 */
@Injectable()
export class ModerationService {
  private readonly logger = new Logger(ModerationService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
    private readonly accountState: AccountStateService,
  ) {}

  // ── Sanctions ──────────────────────────────────────────────────────────────

  async applySanction(admin: AdminContext, userId: string, dto: SanctionDto) {
    requireRole(admin, SANCTION_MIN_ROLE[dto.kind], `A ${dto.kind}`);

    const { data: target, error } = await this.supabase.client
      .from('users')
      .select('id, role')
      .eq('id', userId)
      .maybeSingle();
    if (error) throw toHttpError(error);
    if (!target) throw new NotFoundException({ code: 'MODERATION_NOT_FOUND', message: 'Account not found.' });

    // Moderating the marketplace account of someone who runs the dashboard is a
    // decision for the top of the ladder, whatever the sanction.
    if (target.role === 'admin' && admin.role !== 'super_admin') {
      throw new ForbiddenException({
        code: 'ROLE_REQUIRED',
        message: "Only a super admin can act on an administrator's account.",
      });
    }

    // Closing a report through a sanction is still closing it: same lock as resolve.
    if (dto.report_id && dto.resolve_report) {
      const report = await this.requireReport(dto.report_id);
      const assignee = report.assigned_admin_id as string | null;
      if (assignee && assignee !== admin.id && !roleAtLeast(admin.role, 'senior_admin')) {
        throw new ConflictException({
          code: 'MODERATION_CONFLICT',
          message: 'This report is assigned to another admin.',
        });
      }
    }

    const endsAt = sanctionEnd(dto.kind, dto.duration_days);
    if (dto.hide_listings && !['suspension', 'ban', 'marketplace'].includes(dto.kind)) {
      throw new BadRequestException({
        code: 'MODERATION_INVALID',
        message: 'Listings can only be hidden with a suspension, ban or marketplace restriction.',
      });
    }

    const result = await this.rpc<SanctionResult>('moderation_apply_sanction', {
      p_admin_id: admin.id,
      p_user_id: userId,
      p_kind: dto.kind,
      p_reason: dto.reason,
      p_internal_note: dto.internal_note ?? null,
      p_ends_at: endsAt,
      p_report_id: dto.report_id ?? null,
      p_resolve_report: dto.resolve_report ?? false,
      p_hide_listings: dto.hide_listings ?? false,
      p_request_id: RequestContextStore.requestId() ?? null,
    });

    this.accountState.invalidate(userId);
    this.logger.log(
      `[MODERATION] ${result.action_type} user=${userId} by=${admin.email} (${admin.role}) ` +
        `action=${result.action_id}${dto.report_id ? ` report=${dto.report_id}` : ''}`,
    );
    await this.notify(SANCTION_NOTICE[dto.kind](userId));
    return result;
  }

  async liftRestriction(admin: AdminContext, restrictionId: string, dto: LiftRestrictionDto) {
    const { data: restriction, error } = await this.supabase.client
      .from('account_restrictions')
      .select('id, user_id, kind')
      .eq('id', restrictionId)
      .maybeSingle();
    if (error) throw toHttpError(error);
    if (!restriction) {
      throw new NotFoundException({ code: 'MODERATION_NOT_FOUND', message: 'Restriction not found.' });
    }
    const kind = restriction.kind as RestrictionKind;
    requireRole(admin, LIFT_MIN_ROLE[kind], `Lifting a ${kind}`);

    const result = await this.rpc<{ action_id: string; user_id: string; kind: string }>(
      'moderation_lift_restriction',
      {
        p_admin_id: admin.id,
        p_restriction_id: restrictionId,
        p_reason: dto.reason,
        p_internal_note: dto.internal_note ?? null,
        p_request_id: RequestContextStore.requestId() ?? null,
      },
    );

    this.accountState.invalidate(restriction.user_id as string);
    this.logger.log(`[MODERATION] restriction_lifted ${restrictionId} (${kind}) by=${admin.email}`);
    await this.notify({
      userId: restriction.user_id as string,
      type: 'account_restored',
      title: 'Restriction lifted',
      body: 'A restriction on your Help24 account has been lifted.',
      data: {},
    });
    return result;
  }

  // ── Reports ────────────────────────────────────────────────────────────────

  async triageReport(admin: AdminContext, reportId: string, dto: TriageReportDto) {
    const report = await this.requireReport(reportId);
    const assignee = report.assigned_admin_id as string | null;
    const closed = report.status === 'resolved' || report.status === 'dismissed';

    let assignTo: string | null = null;
    let unassign = false;

    if (dto.assign === 'me') {
      // The same case lock the disputes centre uses: a report someone else is
      // working stays theirs unless a super admin takes it over.
      if (assignee && assignee !== admin.id && admin.role !== 'super_admin') {
        throw new ConflictException({
          code: 'MODERATION_CONFLICT',
          message: 'This report is assigned to another admin.',
        });
      }
      assignTo = admin.id;
    } else if (dto.assign === 'none') {
      if (assignee && assignee !== admin.id && !roleAtLeast(admin.role, 'senior_admin')) {
        throw new ConflictException({
          code: 'MODERATION_CONFLICT',
          message: 'Only a senior admin can release a report someone else is working.',
        });
      }
      unassign = true;
    }
    if (dto.assign_to) {
      requireRole(admin, 'senior_admin', 'Assigning a report to someone else');
      assignTo = dto.assign_to;
    }
    // Re-grading or moving someone else's case is the same lock as resolving it.
    if ((dto.status || dto.severity) && assignee && assignee !== admin.id && !roleAtLeast(admin.role, 'senior_admin')) {
      throw new ConflictException({
        code: 'MODERATION_CONFLICT',
        message: 'This report is assigned to another admin.',
      });
    }
    // Reopening reverses a decision someone made; that is a senior call.
    if (closed && dto.status) {
      requireRole(admin, 'senior_admin', 'Reopening a closed report');
    }

    return this.rpc('moderation_update_report', {
      p_admin_id: admin.id,
      p_report_id: reportId,
      p_status: dto.status ?? null,
      p_severity: dto.severity ?? null,
      p_assign_to: assignTo,
      p_unassign: unassign,
      p_reason: dto.reason ?? null,
      p_request_id: RequestContextStore.requestId() ?? null,
    });
  }

  async resolveReport(admin: AdminContext, reportId: string, dto: ResolveReportDto) {
    const report = await this.requireReport(reportId);
    const assignee = report.assigned_admin_id as string | null;
    if (assignee && assignee !== admin.id && !roleAtLeast(admin.role, 'senior_admin')) {
      throw new ConflictException({
        code: 'MODERATION_CONFLICT',
        message: 'This report is assigned to another admin.',
      });
    }
    return this.rpc('moderation_resolve_report', {
      p_admin_id: admin.id,
      p_report_id: reportId,
      p_outcome: dto.outcome,
      p_reason: dto.reason,
      p_internal_note: dto.internal_note ?? null,
      p_request_id: RequestContextStore.requestId() ?? null,
    });
  }

  async addNote(admin: AdminContext, target: { userId?: string; reportId?: string }, note: string) {
    return this.rpc('moderation_add_note', {
      p_admin_id: admin.id,
      p_note: note,
      p_user_id: target.userId ?? null,
      p_report_id: target.reportId ?? null,
      p_request_id: RequestContextStore.requestId() ?? null,
    });
  }

  // ── Content ────────────────────────────────────────────────────────────────

  async setContentState(
    admin: AdminContext,
    contentType: 'post' | 'message',
    contentId: string,
    action: 'remove' | 'restore',
    dto: ContentActionDto,
  ) {
    const result = await this.rpc<{ action_id: string; owner_user_id: string }>('moderation_set_content_state', {
      p_admin_id: admin.id,
      p_content_type: contentType,
      p_content_id: contentId,
      p_action: action,
      p_reason: dto.reason,
      p_internal_note: dto.internal_note ?? null,
      p_report_id: dto.report_id ?? null,
      p_request_id: RequestContextStore.requestId() ?? null,
    });

    this.logger.log(`[MODERATION] content_${action} ${contentType} ${contentId} by=${admin.email}`);
    // A hidden LISTING is something its owner will notice missing and deserves
    // an explanation route. A hidden message is not announced: its sender
    // already sees it as deleted, and a notice adds nothing but friction.
    if (contentType === 'post' && action === 'remove') {
      await this.notify({
        userId: result.owner_user_id,
        type: 'content_removed',
        title: 'Listing hidden',
        body: "One of your listings was hidden because it doesn't meet Help24's guidelines. Tap for help.",
        data: {},
      });
    }
    return result;
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private async requireReport(reportId: string): Promise<Record<string, unknown>> {
    const { data, error } = await this.supabase.client
      .from('user_reports')
      .select('id, status, assigned_admin_id, reported_user_id')
      .eq('id', reportId)
      .maybeSingle();
    if (error) throw toHttpError(error);
    if (!data) throw new NotFoundException({ code: 'MODERATION_NOT_FOUND', message: 'Report not found.' });
    return data;
  }

  private async rpc<T = Record<string, unknown>>(fn: string, args: Record<string, unknown>): Promise<T> {
    const { data, error } = await this.supabase.client.rpc(fn, args);
    if (error) {
      const http = toHttpError(error);
      if (http.getStatus() >= 500) {
        this.logger.error(`[MODERATION] ${fn} failed (${error.code ?? '?'}): ${error.message}`);
      }
      throw http;
    }
    return data as T;
  }

  /** Best-effort: a failed push never un-does a decision that has committed. */
  private async notify(payload: NotificationPayload): Promise<void> {
    try {
      await this.notifications.send(payload);
    } catch (e) {
      this.logger.warn(`[MODERATION] notification ${payload.type} not sent: ${(e as Error).message}`);
    }
  }
}

export interface SanctionResult {
  action_id: string;
  action_type: string;
  restriction_id: string | null;
  superseded: string[];
  hidden_posts: string[];
  report_resolved: boolean;
  state: { status: string; restrictions: unknown[] };
}

function requireRole(admin: AdminContext, needed: Parameters<typeof roleAtLeast>[1], what: string): void {
  if (!roleAtLeast(admin.role, needed)) {
    throw new ForbiddenException({
      code: 'ROLE_REQUIRED',
      message: `${what} requires the ${needed.replace('_', ' ')} role or higher.`,
    });
  }
}

/**
 * When a sanction ends, computed HERE from a duration rather than accepted as a
 * timestamp from the dashboard, so a skewed browser clock cannot shorten or
 * lengthen a suspension. The database re-validates the window.
 */
export function sanctionEnd(kind: SanctionKind, durationDays?: number): string | null {
  if (kind === 'suspension') {
    if (!durationDays) {
      throw new BadRequestException({ code: 'MODERATION_INVALID', message: 'A suspension needs a duration.' });
    }
    return new Date(Date.now() + durationDays * DAY_MS).toISOString();
  }
  if (kind === 'messaging' || kind === 'marketplace') {
    return durationDays ? new Date(Date.now() + durationDays * DAY_MS).toISOString() : null;
  }
  if (durationDays) {
    throw new BadRequestException({ code: 'MODERATION_INVALID', message: `A ${kind} has no duration.` });
  }
  return null;
}

/**
 * What the affected person is told, per sanction. Generic on purpose: the
 * `notifications` table is readable more widely than it should be (a
 * pre-existing exposure reported separately), and the reason belongs on the
 * account-status screen the notification opens, not in a push.
 */
const SANCTION_NOTICE: Readonly<Record<SanctionKind, (userId: string) => NotificationPayload>> = {
  warning: (userId) => ({
    userId,
    type: 'account_warning',
    title: 'Policy warning',
    body: 'Your Help24 account has received a policy warning. Tap to read it.',
    data: {},
  }),
  suspension: (userId) => ({
    userId,
    type: 'account_suspended',
    title: 'Account suspended',
    body: 'Your Help24 account has been temporarily suspended. Tap for details and how to get help.',
    data: {},
  }),
  ban: (userId) => ({
    userId,
    type: 'account_banned',
    title: 'Account banned',
    body: 'Your Help24 account has been banned. Tap for details and how to appeal.',
    data: {},
  }),
  messaging: (userId) => ({
    userId,
    type: 'account_restricted',
    title: 'Account restricted',
    body: 'Messaging on your Help24 account has been restricted. Tap for details.',
    data: {},
  }),
  marketplace: (userId) => ({
    userId,
    type: 'account_restricted',
    title: 'Account restricted',
    body: 'Posting, applying and payments on your Help24 account have been restricted. Tap for details.',
    data: {},
  }),
};
