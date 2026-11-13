import "server-only";
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";

/**
 * Storage links that stay on admin.help24.co.ke.
 *
 * Photos and documents in the console come back from the backend as signed
 * Supabase Storage links (`https://<project>.supabase.co/storage/v1/...`).
 * Opened in a tab, that address is what an admin sees and can copy. Instead,
 * the page hands the browser `/dashboard/media/<token>`: the signed link,
 * sealed with AES-256-GCM so it can be neither read nor altered, and served
 * back through app/dashboard/media/[token]/route.ts. The route sits under
 * /dashboard, so middleware requires an admin session before it opens anything.
 *
 * Only links to this project's Storage are sealed; anything else passes
 * through unchanged. Without a key (a local build with no service key) links
 * pass through too: a working link beats a broken one.
 */

const PREFIX = "/dashboard/media/";

function storageOrigin(): string | null {
  try {
    return new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").origin;
  } catch {
    return null;
  }
}

function key(): Buffer | null {
  const secret = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!secret) return null;
  return createHash("sha256").update(`help24-admin-media:${secret}`).digest();
}

/** Whether [url] is a link into this project's Storage. */
export function isStorageUrl(url: string): boolean {
  const origin = storageOrigin();
  if (!origin) return false;
  try {
    const u = new URL(url);
    return u.origin === origin && u.pathname.startsWith("/storage/v1/");
  } catch {
    return false;
  }
}

/** The console's own address for a Storage link; any other value unchanged. */
export function maskMediaUrl<T extends string | null | undefined>(url: T): T {
  if (!url || !isStorageUrl(url)) return url;
  const k = key();
  if (!k) return url;
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", k, iv);
  const body = Buffer.concat([cipher.update(url, "utf8"), cipher.final()]);
  const token = Buffer.concat([iv, cipher.getAuthTag(), body]).toString("base64url");
  return `${PREFIX}${token}` as T;
}

/** The Storage link inside a token, or null if it was altered or is not ours. */
export function openMediaToken(token: string): string | null {
  const k = key();
  if (!k) return null;
  try {
    const raw = Buffer.from(token, "base64url");
    if (raw.length < 29) return null;
    const decipher = createDecipheriv("aes-256-gcm", k, raw.subarray(0, 12));
    decipher.setAuthTag(raw.subarray(12, 28));
    const url = Buffer.concat([decipher.update(raw.subarray(28)), decipher.final()]).toString("utf8");
    return isStorageUrl(url) ? url : null;
  } catch {
    return null;
  }
}

/**
 * [data] with every Storage link in it replaced by the console's own address,
 * however deeply it sits. For a page's data just before it is rendered, so
 * no component has to know which fields hold links.
 */
export function maskMediaUrls<T>(data: T): T {
  if (typeof data === "string") return maskMediaUrl(data) as T;
  if (Array.isArray(data)) return data.map((v) => maskMediaUrls(v)) as T;
  if (data && typeof data === "object" && Object.getPrototypeOf(data) === Object.prototype) {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(data as Record<string, unknown>)) out[k] = maskMediaUrls(v);
    return out as T;
  }
  return data;
}
