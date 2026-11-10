import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { randomUUID } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';

/** A photo on a message, as stored in support_messages.attachments (migration 143). */
export interface StoredAttachment {
  path: string;
  mime: string;
}

/** A photo as shown: a short-lived link, never the storage path. */
export interface ShownAttachment {
  url: string;
  mime: string;
}

/**
 * Service-role gateway to the PRIVATE `support-attachments` bucket (Message
 * Help24 photos). Members never touch Storage directly:
 *   1. the app asks for signed UPLOAD urls (issueUploadUrls), each under the
 *      member's own prefix `members/<uid>/`;
 *   2. it uploads the bytes straight to Storage with them;
 *   3. it sends the message naming those paths; the backend checks each one is
 *      under that member's prefix and really exists (verify);
 *   4. every read mints short-lived signed DOWNLOAD links (show).
 * The bucket itself enforces type and size, whatever the app claims.
 */
@Injectable()
export class SupportStorageService {
  private readonly logger = new Logger(SupportStorageService.name);

  static readonly BUCKET = 'support-attachments';
  static readonly MAX_FILES = 5;
  /** Long enough to scroll a thread; a reload makes fresh ones. */
  static readonly DOWNLOAD_TTL_SECONDS = 60 * 60;
  static readonly ALLOWED: Readonly<Record<string, string>> = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp',
  };

  constructor(private readonly supabase: SupabaseService) {}

  private get bucket() {
    return this.supabase.client.storage.from(SupportStorageService.BUCKET);
  }

  static prefixFor(userId: string): string {
    return `members/${userId}/`;
  }

  /** Signed upload links for up to MAX_FILES photos, under the member's own prefix. */
  async issueUploadUrls(userId: string, files: Array<{ content_type: string }>) {
    if (!files?.length) throw new BadRequestException('Choose a photo first.');
    if (files.length > SupportStorageService.MAX_FILES) {
      throw new BadRequestException(`Up to ${SupportStorageService.MAX_FILES} photos at a time.`);
    }
    const out: Array<{ path: string; signed_url: string; token: string; mime: string }> = [];
    for (const f of files) {
      const mime = (f.content_type ?? '').toLowerCase();
      const ext = SupportStorageService.ALLOWED[mime];
      if (!ext) throw new BadRequestException('Only photos can be sent (JPG, PNG or WebP).');
      const path = `${SupportStorageService.prefixFor(userId)}${randomUUID()}.${ext}`;
      const { data, error } = await this.bucket.createSignedUploadUrl(path);
      if (error || !data) {
        this.logger.error(`[SUPPORT_STORAGE] could not sign an upload: ${error?.message}`);
        throw new BadRequestException('Could not prepare the upload. Please try again.');
      }
      out.push({ path, signed_url: data.signedUrl, token: data.token, mime });
    }
    return { files: out };
  }

  /**
   * The photos a member's message names: each under THEIR prefix, of an allowed
   * type, and present in the bucket. A path issued to someone else, or never
   * uploaded, is refused.
   */
  async verify(userId: string, paths: string[]): Promise<StoredAttachment[]> {
    if (paths.length > SupportStorageService.MAX_FILES) {
      throw new BadRequestException(`Up to ${SupportStorageService.MAX_FILES} photos at a time.`);
    }
    const prefix = SupportStorageService.prefixFor(userId);
    const out: StoredAttachment[] = [];
    for (const path of paths) {
      const name = path.startsWith(prefix) ? path.slice(prefix.length) : '';
      const match = /^[0-9a-f-]{36}\.(jpg|png|webp)$/.exec(name);
      if (!match) throw new BadRequestException('That photo does not belong to this conversation.');
      const { data, error } = await this.bucket.list(prefix.slice(0, -1), { search: name, limit: 1 });
      if (error || !data?.some((o) => o.name === name)) {
        throw new BadRequestException('A photo did not finish uploading. Please try again.');
      }
      const mime = Object.entries(SupportStorageService.ALLOWED).find(([, ext]) => ext === match[1])![0];
      out.push({ path, mime });
    }
    return out;
  }

  /** Short-lived links for stored photos. Never throws: a photo that cannot be signed is left out. */
  async show(attachments: unknown): Promise<ShownAttachment[]> {
    if (!Array.isArray(attachments) || attachments.length === 0) return [];
    const shown: ShownAttachment[] = [];
    for (const a of attachments as StoredAttachment[]) {
      if (!a?.path || typeof a.path !== 'string') continue;
      const { data, error } = await this.bucket.createSignedUrl(a.path, SupportStorageService.DOWNLOAD_TTL_SECONDS);
      if (error || !data) {
        this.logger.warn(`[SUPPORT_STORAGE] could not sign a photo: ${error?.message}`);
        continue;
      }
      shown.push({ url: data.signedUrl, mime: a.mime });
    }
    return shown;
  }
}
