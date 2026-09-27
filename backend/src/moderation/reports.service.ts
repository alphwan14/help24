import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { CreateReportDto } from './dto/report.dto';
import { referenceOf } from './moderation.constants';
import { isDuplicateReport, toHttpError } from './moderation-errors';

export type ReportReceipt =
  | { status: 'received'; reference: string }
  | { status: 'already_reported'; reference: null };

/**
 * POST /reports — filing an allegation.
 *
 * A THIN FRONT DOOR ON PURPOSE. Every rule that decides whether a report is
 * accepted lives in the database trigger (migration 114, §6), because the
 * shipped app still files reports by a second door — a direct insert — and one
 * rulebook for both doors is the only way they cannot drift. That trigger:
 *
 *   • derives the REPORTED person from the target (never trusts the client),
 *   • requires a reporter to be IN a conversation to report a message from it,
 *     and to OWN a listing to report an application to it,
 *   • checks the category fits the target, snapshots the content, and
 *     computes the initial severity,
 *   • refuses self-reports, repeats within a day, and more than ten reports a
 *     day (five about one account).
 *
 * What this layer adds is what only a server can: a VERIFIED reporter
 * (@AuthCritical binds the token's uid onto reporter_id), a rate limit, the
 * evidence paths it issued, and the confirmation notification.
 */
@Injectable()
export class ReportsService {
  private readonly logger = new Logger(ReportsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
  ) {}

  async create(dto: CreateReportDto): Promise<ReportReceipt> {
    const reporterId = dto.reporter_id?.trim();
    if (!reporterId) {
      throw new BadRequestException({ code: 'AUTH_REQUIRED', message: 'Sign in to report something.' });
    }

    // Context columns apply only to reporting a PERSON. For every other target
    // the database derives them from the target itself.
    const aboutPerson = dto.target_type === 'user';
    const row = {
      reporter_id: reporterId,
      target_type: dto.target_type,
      target_id: dto.target_id.trim(),
      reason: dto.category,
      details: (dto.details ?? '').trim(),
      chat_id: aboutPerson ? dto.chat_id ?? null : null,
      post_id: aboutPerson ? dto.post_id ?? null : null,
      evidence: (dto.evidence ?? []).map((e) => ({
        path: e.path,
        mime_type: e.mime_type,
        ...(e.size_bytes ? { size_bytes: e.size_bytes } : {}),
      })),
      source: 'api',
    };

    const { data, error } = await this.supabase.client
      .from('user_reports')
      .insert(row)
      .select('id')
      .single();

    if (error) {
      // Reporting the same thing twice is not an error the person made — they
      // are simply told it is already with the team.
      if (isDuplicateReport(error)) {
        return { status: 'already_reported', reference: null };
      }
      const http = toHttpError(error);
      if (http.getStatus() >= 500) {
        this.logger.error(`[REPORTS] insert failed (${error.code ?? '?'}): ${error.message}`);
      }
      throw http;
    }

    const id = data.id as string;
    this.logger.log(`[REPORTS] filed ${id} target=${row.target_type} category=${row.reason} by=${reporterId}`);

    // The confirmation carries NOTHING about the target or the outcome: the
    // notifications table is readable more widely than it should be (reported
    // separately), and a reporter is not owed the result of an investigation.
    void this.notifications
      .send({
        userId: reporterId,
        type: 'report_received',
        title: 'Report received',
        body: 'Thanks for letting us know. Our team will review your report.',
        data: {},
      })
      .catch((e: unknown) =>
        this.logger.warn(`[REPORTS] confirmation not sent: ${e instanceof Error ? e.message : String(e)}`),
      );

    return { status: 'received', reference: referenceOf(id) };
  }
}
