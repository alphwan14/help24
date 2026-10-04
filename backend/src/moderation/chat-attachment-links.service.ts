import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../supabase/supabase.service';

/** The private bucket chat photos and documents live in (migration 118). */
export const CHAT_ATTACHMENT_BUCKET = 'chat-attachments';

const UUID = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const UUID_RE = new RegExp(`^${UUID}$`);
const PRIVATE_REF = new RegExp(`^chat-attachments/(${UUID})/(${UUID})\\.(jpg|png|gif|webp|pdf|doc|docx)$`);
const LEGACY_FILE = new RegExp(`^(${UUID})/([0-9A-Za-z_-]{1,80})\\.([A-Za-z]{3,4})$`);
/** A Firebase uid as it may appear in an object key. */
const SENDER_RE = /^[A-Za-z0-9_-]{1,128}$/;
const KIND: Record<string, 'image' | 'file'> = {
  jpg: 'image', png: 'image', gif: 'image', webp: 'image', pdf: 'file', doc: 'file', docx: 'file',
};

export interface AttachmentRow {
  id?: unknown;
  chat_id?: unknown;
  sender_id?: unknown;
  type?: unknown;
  attachment_url?: unknown;
}

export interface AttachmentObject {
  /** The object's key in the private bucket: `<chat>/<sender>/<message>.<ext>`. */
  key: string;
  ext: string;
  /** The old public address, for a row not yet migrated off the public bucket. */
  legacyUrl: string | null;
}

/**
 * The private object a message's attachment IS — or null.
 *
 * The same rule the files Worker applies (workers/help24-files/src/policy.js):
 * `attachment_url` is written by clients, so it is never followed as a
 * pointer. The key is derived from the row's OWN chat id, SENDER and message
 * id — an object lives in its uploader's folder, so a row cannot be made to
 * show one participant's file as the other's. The
 * stored reference only contributes the extension, and only when it names
 * that same chat (and, for a private reference, that same message). So a row
 * cannot be made to sign someone else's file, and a migration-114 report
 * snapshot — which kept the reference as it was when the report was filed —
 * still resolves to the right object after the file moves to private storage.
 */
export function attachmentObject(row: AttachmentRow, supabaseUrl: string | null): AttachmentObject | null {
  const ref = typeof row.attachment_url === 'string' ? row.attachment_url : '';
  const chatId = String(row.chat_id ?? '').toLowerCase();
  const id = String(row.id ?? '').toLowerCase();
  if (!ref || ref.length > 600 || !UUID_RE.test(chatId) || !UUID_RE.test(id)) return null;
  const kind = row.type === 'image' || row.type === 'file' ? row.type : null;
  if (!kind) return null;
  const sender = typeof row.sender_id === 'string' ? row.sender_id : '';
  if (!SENDER_RE.test(sender)) return null;

  const priv = PRIVATE_REF.exec(ref);
  if (priv) {
    const [, refChat, refMessage, ext] = priv;
    if (refChat !== chatId || refMessage !== id || KIND[ext] !== kind) return null;
    return { key: `${chatId}/${sender}/${id}.${ext}`, ext, legacyUrl: null };
  }

  if (supabaseUrl) {
    const prefix = `${supabaseUrl.replace(/\/+$/, '')}/storage/v1/object/public/post-images/chat_attachments/`;
    if (ref.startsWith(prefix)) {
      const legacy = LEGACY_FILE.exec(ref.slice(prefix.length));
      if (!legacy) return null;
      const [, folder, , rawExt] = legacy;
      const ext = rawExt.toLowerCase() === 'jpeg' ? 'jpg' : rawExt.toLowerCase();
      if (folder.toLowerCase() !== chatId || KIND[ext] !== kind) return null;
      // The migration copies it to exactly this key.
      return { key: `${chatId}/${sender}/${id}.${ext}`, ext, legacyUrl: ref };
    }
  }
  return null;
}

/**
 * Short-lived links for an ADMIN to view a chat attachment — the same shape
 * as ReportEvidenceService: signed by the backend, ten minutes, minted per
 * view. Only Trust & Safety reads call this, and those routes are admin-only.
 *
 * Nothing here streams bytes; the admin's browser fetches the signed object
 * straight from storage.
 */
@Injectable()
export class ChatAttachmentLinksService {
  private readonly logger = new Logger(ChatAttachmentLinksService.name);

  static readonly VIEW_TTL_SECONDS = 60 * 10;

  constructor(private readonly supabase: SupabaseService) {}

  /** A signed link for [row]'s attachment, or null when it has none it may name. */
  async viewUrl(row: AttachmentRow): Promise<string | null> {
    const object = attachmentObject(row, this.supabase.url ?? null);
    if (!object) return null;
    const { data, error } = await this.supabase.client.storage
      .from(CHAT_ATTACHMENT_BUCKET)
      .createSignedUrl(object.key, ChatAttachmentLinksService.VIEW_TTL_SECONDS);
    if (!error && data?.signedUrl) return data.signedUrl;
    // Not copied to private storage yet: until the migration runs, the file
    // is still at its old (public) address.
    if (object.legacyUrl) return object.legacyUrl;
    this.logger.warn(`[CHAT_ATTACHMENT] could not sign ${object.key.slice(0, 8)}…: ${error?.message}`);
    return null;
  }
}
