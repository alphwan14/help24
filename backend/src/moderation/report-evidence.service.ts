import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';
import { EVIDENCE_BUCKET, MAX_REPORT_EVIDENCE, REPORT_EVIDENCE_MIME } from './moderation.constants';

/**
 * Screenshots attached to a report, in the private evidence bucket.
 *
 * The same flow the disputes centre uses (DisputeStorageService): the app asks
 * for signed UPLOAD urls, PUTs the bytes straight to Storage, then names the
 * paths when it files the report. Nothing here is public; admins read through
 * short-lived signed DOWNLOAD urls minted per view.
 *
 * Every path is `reports/<reporter uid>/<uuid>.<ext>`. Migration 114 refuses a
 * report whose evidence is not under the reporter's own prefix, so a path
 * issued to one person cannot be attached to another person's report.
 */
@Injectable()
export class ReportEvidenceService {
  private readonly logger = new Logger(ReportEvidenceService.name);

  static readonly DOWNLOAD_TTL_SECONDS = 60 * 10;

  constructor(private readonly supabase: SupabaseService) {}

  private get bucket() {
    return this.supabase.client.storage.from(EVIDENCE_BUCKET);
  }

  async issueUploadUrls(
    reporterId: string,
    files: Array<{ content_type: string; file_name?: string }>,
  ): Promise<Array<{ path: string; signed_url: string; token: string; mime_type: string }>> {
    if (!reporterId) throw new BadRequestException('A signed-in reporter is required.');
    if (!files?.length || files.length > MAX_REPORT_EVIDENCE) {
      throw new BadRequestException(`Attach between 1 and ${MAX_REPORT_EVIDENCE} screenshots.`);
    }

    const out: Array<{ path: string; signed_url: string; token: string; mime_type: string }> = [];
    for (const file of files) {
      const mime = file.content_type?.toLowerCase?.() ?? '';
      const ext = REPORT_EVIDENCE_MIME[mime];
      if (!ext) throw new BadRequestException('Screenshots must be JPG, PNG or WEBP.');
      const path = `reports/${reporterId}/${randomUUID()}.${ext}`;
      const { data, error } = await this.bucket.createSignedUploadUrl(path);
      if (error || !data) {
        this.logger.error(`[REPORT_EVIDENCE] could not sign an upload for ${path}: ${error?.message}`);
        throw new BadRequestException('Could not prepare the upload. Please try again.');
      }
      out.push({ path, signed_url: data.signedUrl, token: data.token, mime_type: mime });
    }
    return out;
  }

  /** A short-lived link for an admin to view one item. Null when it cannot be signed. */
  async sign(path: string | null | undefined): Promise<string | null> {
    if (!path) return null;
    const { data, error } = await this.bucket.createSignedUrl(path, ReportEvidenceService.DOWNLOAD_TTL_SECONDS);
    if (error || !data) {
      this.logger.warn(`[REPORT_EVIDENCE] could not sign ${path}: ${error?.message}`);
      return null;
    }
    return data.signedUrl;
  }
}
