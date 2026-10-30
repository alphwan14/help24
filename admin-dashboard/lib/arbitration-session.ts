import "server-only";
import { cookies } from "next/headers";
import { ADMIN_TOKEN_COOKIE, ApiError, adminRequest, restoreAdminSession } from "./api";
import { getServerAccessToken } from "./supabase-server";

/** The cookie's lifetime — and, since migration 133, the backend key's. */
const TWELVE_HOURS = 60 * 60 * 12;

/** Store a backend key in the httpOnly cookie. Server Actions and Route Handlers only. */
export async function storeArbitrationToken(token: string): Promise<void> {
  (await cookies()).set(ADMIN_TOKEN_COOKIE, token, {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
    maxAge: TWELVE_HOURS,
  });
}

/**
 * Mint a fresh backend key from the signed-in Supabase session and store it —
 * the same restore AdminShell runs on load (/api/admin/session/restore): the
 * backend verifies the session and the identity link itself, so nothing here
 * decides who is an admin. Null when the session cannot be turned into access
 * (signed out, not linked, disabled).
 */
export async function renewArbitration(): Promise<string | null> {
  const accessToken = await getServerAccessToken();
  if (!accessToken) return null;
  try {
    const result = await restoreAdminSession(accessToken);
    await storeArbitrationToken(result.token);
    return result.token;
  } catch {
    return null;
  }
}

/**
 * adminRequest for Server Actions and Route Handlers. A key the backend
 * refuses (401: expired after 12 hours, or retired by a restore elsewhere
 * before migration 133) is renewed once and the call retried, so an open tab
 * keeps working instead of answering "Invalid admin token." until a reload.
 * The retry is safe for writes: a 401 comes from the guard, before any handler
 * ran. Anything else — and a renewal that fails — is the original error.
 *
 * Not for Server Components: they cannot set the cookie, so they would mint a
 * key per render. AdminShell restores those on load.
 */
export async function adminActionRequest<T>(
  path: string,
  init?: RequestInit & { token?: string },
): Promise<T> {
  try {
    return await adminRequest<T>(path, init);
  } catch (err) {
    if (!(err instanceof ApiError) || err.status !== 401 || init?.token) throw err;
    const token = await renewArbitration();
    if (!token) throw err;
    return adminRequest<T>(path, { ...init, token });
  }
}
