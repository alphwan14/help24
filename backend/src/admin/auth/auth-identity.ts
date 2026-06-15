// =============================================================================
// RULE — IDENTITY STANDARDIZATION (read before touching any auth code)
// -----------------------------------------------------------------------------
//   Supabase Auth (auth.users.id, a UUID) = the ONLY valid identity for
//                                           authentication operations.
//   public.users.id (a Firebase UID, TEXT) = application METADATA ONLY.
//   NEVER MIX. A Firebase UID must never reach a Supabase Auth admin call.
//
// Every value passed to auth.admin.updateUserById / deleteUser / getUserById
// MUST originate from Supabase Auth (createUser response or listUsers) and MUST
// pass assertAuthUuid() first. This module is that single chokepoint.
// =============================================================================

/**
 * Strict RFC-4122 UUID (versioned + variant). Supabase Auth issues v4 UUIDs,
 * which satisfy this. Firebase UIDs (e.g. "k3Jd9fM2nP...") never do.
 */
export const AUTH_UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** True only for a well-formed Supabase Auth UUID. */
export function isAuthUuid(id: unknown): id is string {
  return typeof id === 'string' && AUTH_UUID_RE.test(id);
}

/**
 * Guard placed before EVERY Supabase Auth admin call that takes a user id.
 * Throws a descriptive error if a Firebase UID / public.users.id slipped in.
 *
 * @param id      the value about to be handed to auth.admin.*
 * @param context short label for the error/log (e.g. "invite acceptance")
 */
export function assertAuthUuid(id: unknown, context = 'auth operation'): string {
  if (!isAuthUuid(id)) {
    throw new Error(
      `Invalid Auth UUID in ${context}: Firebase UID or public.users.id was ` +
        `passed into Supabase Auth. Only auth.users.id (UUID) is valid. Got: ${String(id)}`,
    );
  }
  return id as string;
}
