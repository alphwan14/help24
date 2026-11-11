import { BadRequestException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHmac, randomUUID, timingSafeEqual } from 'crypto';
import { SupabaseService } from '../supabase/supabase.service';

/** A photo on a message, as stored in support_messages.attachments (migration 143). */
export interface StoredAttachment {
  path: string;
  mime: string;
}

/** A photo as shown: a short-lived Help24 link, never a storage address. */
export interface ShownAttachment {
  url: string;
  mime: string;
}

const HOUR_S = 60 * 60;

/**
 * Service-role gateway to the PRIVATE `support-attachments` bucket (Message
 * Help24 photos). Members never touch Storage directly:
 *   1. the app asks for signed UPLOAD urls (issueUploadUrls), each under the
 *      member's own prefix `members/<uid>/`;
 *   2. it uploads the bytes straight to Storage with them;
 *   3. it sends the message naming those paths; the backend checks each one is
 *      under that member's prefix and really exists (verify);
 *   4. every read gets a Help24 link, `https://api.help24.co.ke/support/photos/
 *      <message>/<n>?e=<expiry>&s=<signature>` (show). The backend checks the
 *      signature and serves the bytes itself (fetchPhoto), so no one ever sees
 *      the storage provider's address or the member's account id in a link.
 * The bucket itself enforces type and size, whatever the app claims.
 */
@Injectable()
export class SupportStorageService {
  private readonly logger = new Logger(SupportStorageService.name);

  static readonly BUCKET = 'support-attachments';
  static readonly MAX_FILES = 5;
  static readonly ALLOWED: Readonly<Record<string, string>> = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp',
  };

  private linkKeyCache: Buffer | null = null;

  constructor(
    private readonly supabase: SupabaseService,
    private readonly config: ConfigService,
  ) {}

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

  // ── Help24 photo links ──────────────────────────────────────────────────

  /**
   * The links for a message's photos, on Help24's own address. Each is good
   * for one to two hours: the expiry is rounded to the hour, so the same photo
   * keeps the same link (and the browser's cached copy) within the hour.
   */
  show(messageId: string, attachments: unknown, now = Date.now()): ShownAttachment[] {
    if (!Array.isArray(attachments) || attachments.length === 0) return [];
    const exp = (Math.floor(now / 1000 / HOUR_S) + 2) * HOUR_S;
    const base = (this.config.get<string>('PUBLIC_API_URL') ?? 'https://api.help24.co.ke').replace(/\/+$/, '');
    return (attachments as StoredAttachment[]).flatMap((a, i) =>
      a && typeof a.path === 'string'
        ? [{ url: `${base}/support/photos/${messageId}/${i}?e=${exp}&s=${this.sign(messageId, i, exp)}`, mime: a.mime }]
        : [],
    );
  }

  /** True when a photo link is genuine and has not expired. */
  checkLink(messageId: string, index: number, exp: number, signature: string, now = Date.now()): boolean {
    const nowS = Math.floor(now / 1000);
    // Expired, or further ahead than a link is ever issued for: refused.
    if (!Number.isInteger(exp) || exp <= nowS || exp > nowS + 3 * HOUR_S) return false;
    if (!/^[A-Za-z0-9_-]{43}$/.test(signature)) return false;
    const expected = Buffer.from(this.sign(messageId, index, exp));
    const given = Buffer.from(signature);
    return expected.length === given.length && timingSafeEqual(expected, given);
  }

  /** The bytes of a stored photo, for the Help24 link to serve. */
  async fetchPhoto(attachment: StoredAttachment): Promise<{ bytes: Buffer; mime: string }> {
    const { data, error } = await this.bucket.download(attachment.path);
    if (error || !data) {
      this.logger.warn(`[SUPPORT_STORAGE] could not read a photo: ${error?.message}`);
      throw new NotFoundException('Photo not found.');
    }
    return { bytes: Buffer.from(await data.arrayBuffer()), mime: attachment.mime };
  }

  private sign(messageId: string, index: number, exp: number): string {
    return createHmac('sha256', this.linkKey()).update(`${messageId}:${index}:${exp}`).digest('base64url');
  }

  /**
   * The key photo links are signed with: derived from the service-role key the
   * backend already holds, under its own label, so there is no new secret to
   * manage and it signs nothing else. Rotating that key ends every open link,
   * which is harmless: the next read issues fresh ones.
   */
  private linkKey(): Buffer {
    if (!this.linkKeyCache) {
      const root = this.config.get<string>('SUPABASE_SERVICE_ROLE_KEY') ?? '';
      if (!root) throw new Error('SUPABASE_SERVICE_ROLE_KEY is not set');
      this.linkKeyCache = createHmac('sha256', root).update('help24/support-photo-links/v1').digest();
    }
    return this.linkKeyCache;
  }
}
