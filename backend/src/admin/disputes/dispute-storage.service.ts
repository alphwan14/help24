import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { SupabaseService } from '../../supabase/supabase.service';

/**
 * Service-role gateway to the PRIVATE `dispute-evidence` storage bucket.
 *
 * Participants never touch Supabase Storage directly. The flow is:
 *   1. client asks the backend for a signed UPLOAD url (issueUploadUrls)
 *   2. client PUTs the bytes straight to Storage using that url + token
 *   3. client tells the backend the object path (DisputesService.submitEvidence)
 *   4. on every read the backend mints a short-TTL signed DOWNLOAD url (sign)
 *
 * Nothing in this bucket is public; the bucket itself enforces the size/MIME
 * limits server-side, so a forged client claim cannot smuggle a bad file in.
 */
@Injectable()
export class DisputeStorageService {
  private readonly logger = new Logger(DisputeStorageService.name);

  static readonly BUCKET = 'dispute-evidence';
  static readonly MAX_FILES_PER_ACTION = 10;
  static readonly MAX_FILE_BYTES = 10 * 1024 * 1024; // 10 MB
  static readonly DOWNLOAD_TTL_SECONDS = 60 * 10; // 10 min — refreshed on each read

  /** MIME → canonical evidence type + extension. The single source of truth for
   *  what we accept; rejects executables, archives, videos, unknown types. */
  static readonly ALLOWED: Record<string, { type: 'image' | 'document'; ext: string }> = {
    'image/jpeg': { type: 'image', ext: 'jpg' },
    'image/png': { type: 'image', ext: 'png' },
    'image/webp': { type: 'image', ext: 'webp' },
    'application/pdf': { type: 'document', ext: 'pdf' },
  };

  constructor(private readonly supabase: SupabaseService) {}

  private get bucket() {
    return this.supabase.client.storage.from(DisputeStorageService.BUCKET);
  }

  /** Validate a declared MIME type, returning its canonical evidence type. */
  static evidenceTypeFor(mime: string): 'image' | 'document' {
    const entry = DisputeStorageService.ALLOWED[mime?.toLowerCase?.() ?? ''];
    if (!entry) {
      throw new BadRequestException(
        `Unsupported file type "${mime}". Allowed: JPG, PNG, WEBP, PDF.`,
      );
    }
    return entry.type;
  }

  /**
   * Issue signed upload URLs for a batch of files scoped to one dispute.
   * Each returned object path is deterministic-by-prefix (`disputes/<id>/...`),
   * which the submit step re-validates so a client cannot register a path it was
   * never granted.
   */
  async issueUploadUrls(
    disputeId: string,
    files: Array<{ file_name: string; content_type: string }>,
  ): Promise<Array<{ path: string; signed_url: string; token: string; type: 'image' | 'document' }>> {
    if (!files?.length) throw new BadRequestException('At least one file is required.');
    if (files.length > DisputeStorageService.MAX_FILES_PER_ACTION) {
      throw new BadRequestException(
        `Too many files: max ${DisputeStorageService.MAX_FILES_PER_ACTION} per upload.`,
      );
    }

    const out: Array<{ path: string; signed_url: string; token: string; type: 'image' | 'document' }> = [];
    for (const f of files) {
      const meta = DisputeStorageService.ALLOWED[f.content_type?.toLowerCase?.() ?? ''];
      if (!meta) {
        throw new BadRequestException(
          `Unsupported file type "${f.content_type}". Allowed: JPG, PNG, WEBP, PDF.`,
        );
      }
      const path = `disputes/${disputeId}/${randomUUID()}.${meta.ext}`;
      const { data, error } = await this.bucket.createSignedUploadUrl(path);
      if (error || !data) {
        this.logger.error(`[DISPUTE_STORAGE] sign upload failed for ${path}: ${error?.message}`);
        throw new BadRequestException('Could not create an upload URL.');
      }
      out.push({ path, signed_url: data.signedUrl, token: data.token, type: meta.type });
    }
    return out;
  }

  /**
   * Confirm an object path belongs to this dispute's prefix. Defends against a
   * participant registering a path issued for a different case.
   */
  static assertPathBelongs(disputeId: string, path: string): void {
    if (!path || !path.startsWith(`disputes/${disputeId}/`)) {
      throw new BadRequestException('Evidence path does not belong to this dispute.');
    }
  }

  /**
   * Mint a short-TTL signed download URL for a stored object PATH. If the value
   * already looks like an absolute URL (legacy rows from before private storage),
   * it is returned unchanged. Never throws — returns null so a single bad object
   * cannot break a whole case view.
   */
  async sign(pathOrUrl: string | null): Promise<string | null> {
    if (!pathOrUrl) return null;
    if (/^https?:\/\//i.test(pathOrUrl)) return pathOrUrl; // legacy full URL
    const { data, error } = await this.bucket.createSignedUrl(
      pathOrUrl,
      DisputeStorageService.DOWNLOAD_TTL_SECONDS,
    );
    if (error || !data) {
      this.logger.warn(`[DISPUTE_STORAGE] sign download failed for ${pathOrUrl}: ${error?.message}`);
      return null;
    }
    return data.signedUrl;
  }
}
