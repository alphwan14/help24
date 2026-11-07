import {
  BadRequestException,
  ConflictException,
  Injectable,
  Logger,
  NotFoundException,
} from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';
import { NotificationsService } from '../notifications/notifications.service';
import { AdminContext } from '../admin/auth/admin-role';
import {
  DOCUMENT_LABELS,
  FILE_ROLES,
  REJECTION_REASONS,
  REVIEW_TARGET_HOURS,
  SIGNED_URL_TTL_SECONDS,
  VERIFICATION_BUCKET,
  VerificationDocumentType,
  VerificationKind,
  VerificationStatus,
  decisionNotice,
} from './verification-rules';
import { ReviewVerificationDto } from './dto/verifications-admin.dto';

export interface VerificationRow {
  id: string;
  user_id: string;
  kind: VerificationKind;
  document_type: VerificationDocumentType;
  files: string[];
  status: VerificationStatus;
  submitted_at: string;
  reviewed_at: string | null;
  reviewed_by: string | null;
  rejection_reason: string | null;
  expires_at: string | null;
  files_deleted_at: string | null;
}

export interface PersonRow {
  id: string;
  name: string | null;
  profession: string | null;
  phone_number: string | null;
  avatar_url: string | null;
  profile_image: string | null;
  created_at: string | null;
}

const ROW_COLUMNS =
  'id, user_id, kind, document_type, files, status, submitted_at, reviewed_at, reviewed_by, rejection_reason, expires_at, files_deleted_at';

/**
 * The admin side of provider vetting: the review queue, one submission with
 * its documents, and the decision. Every rule (who may be approved, what an
 * approval opens, which listings reopen) lives in the database function
 * review_provider_verification (migration 135); this service lists, signs
 * links and tells the provider.
 */
@Injectable()
export class VerificationsService {
  private readonly logger = new Logger(VerificationsService.name);

  constructor(
    private readonly supabase: SupabaseService,
    private readonly notifications: NotificationsService,
  ) {}

  private get db() {
    return this.supabase.client;
  }

  /** The reasons and labels the review screen offers. */
  meta() {
    return {
      rejection_reasons: REJECTION_REASONS,
      document_labels: DOCUMENT_LABELS,
      review_target_hours: REVIEW_TARGET_HOURS,
    };
  }

  async summary(): Promise<{ pending: number; oldest_submitted_at: string | null; overdue: number }> {
    const { data, error } = await this.db
      .from('provider_verifications')
      .select('submitted_at')
      .eq('status', 'pending')
      .order('submitted_at', { ascending: true })
      .limit(500);
    if (error) throw new Error(`verification summary failed: ${error.message}`);
    const rows = (data ?? []) as Array<{ submitted_at: string }>;
    const cutoff = Date.now() - REVIEW_TARGET_HOURS * 3_600_000;
    return {
      pending: rows.length,
      oldest_submitted_at: rows[0]?.submitted_at ?? null,
      overdue: rows.filter((r) => new Date(r.submitted_at).getTime() < cutoff).length,
    };
  }

  async list(status: VerificationStatus = 'pending') {
    let query = this.db.from('provider_verifications').select(ROW_COLUMNS).eq('status', status);
    query = status === 'pending'
      ? query.order('submitted_at', { ascending: true })
      : query.order('reviewed_at', { ascending: false });
    const { data, error } = await query.limit(200);
    if (error) throw new Error(`verification list failed: ${error.message}`);

    const rows = (data ?? []) as VerificationRow[];
    const people = await this.people(rows.map((r) => r.user_id));
    return {
      items: rows.map((r) => ({
        ...this.publicRow(r),
        person: people.get(r.user_id) ?? null,
      })),
    };
  }

  async get(id: string) {
    const row = await this.row(id);
    const [people, history, state, listings] = await Promise.all([
      this.people([row.user_id]),
      this.db
        .from('provider_verifications')
        .select(ROW_COLUMNS)
        .eq('user_id', row.user_id)
        .order('submitted_at', { ascending: false })
        .limit(20),
      this.db.rpc('provider_vetting_state', { p_user_id: row.user_id }),
      this.vettedListings(row.user_id),
    ]);

    return {
      ...this.publicRow(row),
      person: people.get(row.user_id) ?? null,
      files: await this.signedFiles(row),
      state: (Array.isArray(state.data) ? state.data[0] : state.data) ?? null,
      history: ((history.data ?? []) as VerificationRow[])
        .filter((h) => h.id !== row.id)
        .map((h) => this.publicRow(h)),
      listings,
    };
  }

  async review(id: string, dto: ReviewVerificationDto, admin: AdminContext) {
    const reason = dto.reason?.trim() || null;
    if (dto.decision === 'reject' && !reason) {
      throw new BadRequestException('Give the provider a reason — it is sent to them.');
    }

    const { data, error } = await this.db.rpc('review_provider_verification', {
      p_id: id,
      p_decision: dto.decision,
      p_reason: reason,
      p_reviewer: admin.id,
    });
    if (error) throw this.reviewError(error.message ?? '');

    const result = data as {
      id: string;
      user_id: string;
      kind: VerificationKind;
      document_type: VerificationDocumentType;
      status: VerificationStatus;
      expires_at: string | null;
      listings_changed: number;
    };
    this.logger.log(
      `[VERIFY][REVIEW] id=${id} user=${result.user_id} kind=${result.kind} doc=${result.document_type} ` +
      `decision=${dto.decision} admin=${admin.id} listings_changed=${result.listings_changed}`,
    );

    // Telling the provider must never undo a decision that is already recorded.
    const notice = decisionNotice({ ...result, rejection_reason: reason });
    await this.notifications
      .send({
        userId: result.user_id,
        type: notice.type,
        title: notice.title,
        body: notice.body,
        data: { screen: 'verification', kind: result.kind, status: result.status },
      })
      .catch((e: unknown) => {
        this.logger.warn(`[VERIFY][NOTIFY] user=${result.user_id} failed: ${e instanceof Error ? e.message : String(e)}`);
      });

    return result;
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  private async row(id: string): Promise<VerificationRow> {
    const { data, error } = await this.db.from('provider_verifications').select(ROW_COLUMNS).eq('id', id).maybeSingle();
    if (error) throw new Error(`verification read failed: ${error.message}`);
    if (!data) throw new NotFoundException('No such verification.');
    return data as VerificationRow;
  }

  /** Everything but the storage paths, which only this service turns into links. */
  private publicRow(r: VerificationRow) {
    return {
      id: r.id,
      user_id: r.user_id,
      kind: r.kind,
      document_type: r.document_type,
      document_label: DOCUMENT_LABELS[r.document_type] ?? r.document_type,
      file_count: r.files?.length ?? 0,
      status: r.status,
      submitted_at: r.submitted_at,
      reviewed_at: r.reviewed_at,
      reviewed_by: r.reviewed_by,
      rejection_reason: r.rejection_reason,
      expires_at: r.expires_at,
      files_deleted_at: r.files_deleted_at,
    };
  }

  private async signedFiles(row: VerificationRow) {
    if (row.files_deleted_at) return [];
    const roles = FILE_ROLES[row.document_type] ?? [];
    const bucket = this.db.storage.from(VERIFICATION_BUCKET);
    return Promise.all(
      (row.files ?? []).map(async (path, i) => {
        const { data, error } = await bucket.createSignedUrl(path, SIGNED_URL_TTL_SECONDS);
        return {
          role: roles[i] ?? `File ${i + 1}`,
          is_pdf: /\.pdf$/i.test(path),
          url: error ? null : (data?.signedUrl ?? null),
          error: error ? 'This file could not be opened.' : null,
        };
      }),
    );
  }

  private async people(ids: string[]): Promise<Map<string, PersonRow>> {
    const unique = [...new Set(ids)].filter(Boolean);
    const map = new Map<string, PersonRow>();
    if (unique.length === 0) return map;
    const { data } = await this.db
      .from('users')
      .select('id, name, profession, phone_number, avatar_url, profile_image, created_at')
      .in('id', unique);
    for (const p of (data ?? []) as PersonRow[]) map.set(p.id, p);
    return map;
  }

  /** The person's offers in vetted categories, so the reviewer sees what is at stake. */
  private async vettedListings(userId: string) {
    const { data: tiers } = await this.db.from('categories').select('name, vetting_tier').not('vetting_tier', 'is', null);
    const tierByName = new Map(((tiers ?? []) as Array<{ name: string; vetting_tier: string }>).map((t) => [t.name, t.vetting_tier]));
    if (tierByName.size === 0) return [];
    const { data } = await this.db
      .from('posts')
      .select('id, title, category, status, vetting_label, vetting_hide_at, archived_by, created_at')
      .eq('author_user_id', userId)
      .eq('type', 'offer')
      .in('category', [...tierByName.keys()])
      .order('created_at', { ascending: false })
      .limit(20);
    return ((data ?? []) as Array<Record<string, unknown>>).map((p) => ({
      ...p,
      tier: tierByName.get(p.category as string) ?? null,
    }));
  }

  private reviewError(message: string): Error {
    const text = message.replace(/^HELP24_VERIFICATION_[A-Z_]+:?\s*/, '');
    if (message.includes('HELP24_VERIFICATION_NOT_FOUND')) return new NotFoundException('No such verification.');
    if (message.includes('HELP24_VERIFICATION_ALREADY_REVIEWED')) {
      return new ConflictException(`Someone already decided this one (${text}). Refresh to see it.`);
    }
    if (message.includes('HELP24_VERIFICATION_INVALID')) return new BadRequestException(capitalise(text));
    this.logger.error(`[VERIFY][REVIEW] unexpected database error: ${message}`);
    return new Error('The decision could not be recorded.');
  }
}

function capitalise(s: string): string {
  return s ? s[0].toUpperCase() + s.slice(1) + (/[.!?]$/.test(s) ? '' : '.') : s;
}
