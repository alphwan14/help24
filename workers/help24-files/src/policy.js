// Pure decisions for the Help24 document endpoint. No I/O lives here, so every
// rule that guards a private chat file can be tested without a network.

/** Largest chat attachment accepted. Mirrors the app's picker limit and the
 *  bucket's own `file_size_limit`, so the three cannot disagree. */
export const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;

/** The private bucket every new chat attachment lives in. */
export const PRIVATE_BUCKET = 'chat-attachments';

/** Where attachments lived before this endpoint existed (public bucket). Read
 *  only, through the service key, and only until the migration has moved them. */
export const LEGACY_BUCKET = 'post-images';

/**
 * The ONLY file types a chat attachment may be. Extension is canonical: the
 * stored object key, the served Content-Type and the magic-byte check all key
 * off it, so a file can never be stored as one type and served as another.
 *
 * `inline` decides Content-Disposition: images and PDFs open in the viewer,
 * Word documents download (no browser renders them, and a download keeps the
 * real file name).
 */
export const TYPES = Object.freeze({
  jpg: { mime: 'image/jpeg', kind: 'image', inline: true },
  png: { mime: 'image/png', kind: 'image', inline: true },
  gif: { mime: 'image/gif', kind: 'image', inline: true },
  webp: { mime: 'image/webp', kind: 'image', inline: true },
  pdf: { mime: 'application/pdf', kind: 'file', inline: true },
  doc: { mime: 'application/msword', kind: 'file', inline: false },
  docx: {
    mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    kind: 'file',
    inline: false,
  },
});

const MIME_TO_EXT = Object.freeze(
  Object.fromEntries(Object.entries(TYPES).map(([ext, t]) => [t.mime, ext])),
);

const UUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
const UUID_RE = new RegExp(`^${UUID}$`);
/** A Firebase uid as it may appear in an object key. */
export const SENDER_RE = /^[A-Za-z0-9_-]{1,128}$/;
const PRIVATE_REF_RE = new RegExp(`^${PRIVATE_BUCKET}/(${UUID})/(${UUID})\\.([a-z]{3,4})$`);
const LEGACY_FILE_RE = new RegExp(`^(${UUID})/([0-9A-Za-z_-]{1,80})\\.([A-Za-z]{3,4})$`);

export function isUuid(value) {
  return typeof value === 'string' && UUID_RE.test(value);
}

/** The canonical extension for a declared Content-Type, or null if not allowed. */
export function extForContentType(contentType) {
  if (typeof contentType !== 'string') return null;
  const mime = contentType.split(';')[0].trim().toLowerCase();
  return MIME_TO_EXT[mime] ?? null;
}

/** What `chat_messages.attachment_url` holds for a private attachment. */
export function privateRef(chatId, messageId, ext) {
  return `${PRIVATE_BUCKET}/${chatId.toLowerCase()}/${messageId.toLowerCase()}.${ext}`;
}

/**
 * The object key inside the private bucket: `<chat>/<uploader>/<message>.<ext>`.
 *
 * The uploader is part of the key because `chat_messages` RLS lets either
 * participant insert or edit a row with ANY sender_id in their chat. Without
 * it, A could upload a file and point a row "from B" at it. With it, a read
 * derives the key from the row's sender_id, so only what the sender uploaded
 * can ever be served as theirs. (The row's reference stays
 * `chat-attachments/<chat>/<message>.<ext>`; the sender comes from the row.)
 */
export function privateKey(chatId, senderId, messageId, ext) {
  return `${chatId.toLowerCase()}/${senderId}/${messageId.toLowerCase()}.${ext}`;
}

/**
 * The storage object a message is allowed to serve — or null.
 *
 * THE LOAD-BEARING RULE: the stored reference is never trusted as a pointer.
 * `chat_messages` rows are written by clients, so a participant could store
 * any string there — another chat's key, another bucket, a URL. A reference is
 * honoured only when it names EXACTLY the object this message owns: its own
 * chat folder and (for private objects) its own message id. Everything about
 * the location is derived from the row the database returned — chat, SENDER
 * and id; the reference contributes only the file extension, and that from a
 * fixed allowlist.
 */
export function objectForMessage(row, supabaseUrl) {
  const ref = row?.attachment_url;
  if (typeof ref !== 'string' || ref.length === 0 || ref.length > 600) return null;
  const chatId = String(row.chat_id ?? '').toLowerCase();
  const messageId = String(row.id ?? '').toLowerCase();
  if (!isUuid(chatId) || !isUuid(messageId)) return null;
  const expectedKind = row.type === 'image' ? 'image' : row.type === 'file' ? 'file' : null;
  if (!expectedKind) return null;

  const priv = PRIVATE_REF_RE.exec(ref);
  if (priv) {
    const [, refChat, refMessage, ext] = priv;
    if (refChat.toLowerCase() !== chatId || refMessage.toLowerCase() !== messageId) return null;
    if (TYPES[ext]?.kind !== expectedKind) return null;
    const sender = row.sender_id;
    if (typeof sender !== 'string' || !SENDER_RE.test(sender)) return null;
    return { bucket: PRIVATE_BUCKET, key: privateKey(chatId, sender, messageId, ext), ext, legacy: false };
  }

  const legacyPrefix = `${String(supabaseUrl).replace(/\/+$/, '')}/storage/v1/object/public/${LEGACY_BUCKET}/chat_attachments/`;
  if (ref.startsWith(legacyPrefix)) {
    const legacy = LEGACY_FILE_RE.exec(ref.slice(legacyPrefix.length));
    if (!legacy) return null;
    const [, folder, name, rawExt] = legacy;
    if (folder.toLowerCase() !== chatId) return null;
    let ext = rawExt.toLowerCase();
    if (ext === 'jpeg') ext = 'jpg';
    if (TYPES[ext]?.kind !== expectedKind) return null;
    return {
      bucket: LEGACY_BUCKET,
      key: `chat_attachments/${folder}/${name}.${rawExt}`,
      ext,
      legacy: true,
    };
  }
  return null;
}

/**
 * The access decision for one message, given whether the caller has already
 * been proven a participant of its chat. Not-a-participant and does-not-exist
 * deliberately produce the SAME answer, so the endpoint cannot be used to
 * learn which message ids exist.
 */
export function decide(row, callerIsParticipant, supabaseUrl) {
  if (!row || !callerIsParticipant) return { status: 'not_found' };
  if (row.deleted_for_everyone === true) return { status: 'gone' };
  const object = objectForMessage(row, supabaseUrl);
  if (!object) return { status: 'not_found' };
  return { status: 'ok', object, filename: filenameFor(row, object.ext) };
}

/** The two participants of the message's chat, from the embedded chats row. */
export function participantsOf(row) {
  const chat = Array.isArray(row?.chats) ? row.chats[0] : row?.chats;
  const out = [];
  if (chat && typeof chat.user1 === 'string' && chat.user1) out.push(chat.user1);
  if (chat && typeof chat.user2 === 'string' && chat.user2) out.push(chat.user2);
  return out;
}

/**
 * A file name worth saving. A document keeps the name it was sent with (the
 * message content is the picked file's name); a photo gets a readable one. The
 * stored object is named by uuid, which is what a download used to be called.
 */
export function filenameFor(row, ext) {
  if (row.type === 'file') {
    let name = sanitizeFilename(String(row.content ?? ''));
    if (!name || name === 'File') name = 'help24-document';
    if (!name.toLowerCase().endsWith(`.${ext}`)) name = `${name}.${ext}`;
    return name;
  }
  return `help24-photo-${String(row.id).slice(0, 8).toLowerCase()}.${ext}`;
}

/** Strip anything a header or a file system could misread. */
export function sanitizeFilename(raw) {
  let s = String(raw ?? '').split(/[\\/]/).pop() ?? '';
  // Control characters (a line break could end the header) become spaces;
  // quotes and the characters Windows/Android refuse in names are dropped.
  s = s.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/["<>:|?*;]/g, '');
  s = s.replace(/\s+/g, ' ').trim().replace(/^\.+/, '');
  if (s.length > 120) {
    const dot = s.lastIndexOf('.');
    const ext = dot > 0 && s.length - dot <= 6 ? s.slice(dot) : '';
    s = s.slice(0, 120 - ext.length) + ext;
  }
  return s;
}

/** RFC 6266 Content-Disposition with an ASCII fallback and a UTF-8 name. */
export function contentDisposition(filename, inline) {
  const ascii = filename.replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
  const encoded = encodeURIComponent(filename).replace(
    /['()*]/g,
    (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`,
  );
  return `${inline ? 'inline' : 'attachment'}; filename="${ascii}"; filename*=UTF-8''${encoded}`;
}

/**
 * Whether the bytes really are what the declared type says. Without this a
 * page of HTML could be uploaded as "image/jpeg" and, with a lenient viewer,
 * end up interpreted as something else under the Help24 hostname.
 */
export function bytesMatchType(ext, bytes) {
  const b = bytes;
  const at = (offset, ...sig) => sig.every((v, i) => b[offset + i] === v);
  switch (ext) {
    case 'jpg':
      return b.length > 3 && at(0, 0xff, 0xd8, 0xff);
    case 'png':
      return b.length > 8 && at(0, 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
    case 'gif':
      return b.length > 6 && at(0, 0x47, 0x49, 0x46, 0x38);
    case 'webp':
      return b.length > 12 && at(0, 0x52, 0x49, 0x46, 0x46) && at(8, 0x57, 0x45, 0x42, 0x50);
    case 'pdf': {
      // The header may follow a little junk; the spec allows it within 1024 bytes.
      const limit = Math.min(b.length - 4, 1024);
      for (let i = 0; i <= limit; i++) if (at(i, 0x25, 0x50, 0x44, 0x46)) return true;
      return false;
    }
    case 'doc':
      return b.length > 8 && at(0, 0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1);
    case 'docx':
      return b.length > 4 && at(0, 0x50, 0x4b, 0x03, 0x04);
    default:
      return false;
  }
}

/** A Range header worth forwarding (single byte range only), else null. */
export function safeRange(value) {
  if (typeof value !== 'string') return null;
  const v = value.trim();
  return /^bytes=(\d{1,12})?-(\d{1,12})?$/.test(v) && v !== 'bytes=-' ? v : null;
}
