/**
 * The vocabulary of authenticated identity, in one file.
 *
 * Everything here is a type or a constant — no behaviour — so it can be
 * imported by the middleware, the guard, the verifier and the route audit
 * without any of them depending on each other.
 */

/**
 * How hard the platform enforces authentication right now.
 *
 * The three values are a MIGRATION SEQUENCE, not a preference. Each is a
 * deployable state of the system, and the whole point is that moving between
 * them is an environment-variable change rather than a code change — so the
 * decision to start rejecting requests can be made (and undone) in seconds by
 * whoever is watching the dashboards, not in a release cycle.
 *
 *   off      Identity is resolved and bound when a token is present, and
 *            nothing is ever rejected for its absence. Byte-identical to the
 *            pre-auth behaviour for a client that sends no token.
 *
 *   monitor  Identical RESPONSES to `off` — every request that succeeds today
 *            still succeeds — but every request that `enforce` WOULD have
 *            rejected emits a structured log line saying so, with the reason.
 *            This is the stage that turns "are we ready to enforce?" from a
 *            judgement call into a number you can read off a dashboard.
 *
 *   enforce  Protected routes require a verified token. An identity claimed in
 *            the body that disagrees with the token is a 403.
 *
 * `monitor` is the default deliberately. A deployment that forgets to set the
 * variable must not silently start rejecting a shipped client (which `enforce`
 * would) and must not silently run with no security posture at all and no way
 * to tell (which `off` would). `monitor` is the only value that is both
 * non-breaking and self-reporting.
 */
export type AuthMode = 'off' | 'monitor' | 'enforce';

export const AUTH_MODES: readonly AuthMode[] = ['off', 'monitor', 'enforce'] as const;

/**
 * The authentication scheme a route declares.
 *
 *   firebase  A Firebase ID token from the mobile app. The common case.
 *   admin     An opaque Help24 admin token, checked by AdminAuthGuard. The
 *             Firebase guard stands down entirely for these — see auth.guard.ts.
 *   public    No identity required. Anonymous browsing, health probes, and the
 *             payment-provider callbacks that Daraja posts unauthenticated.
 */
export type AuthScheme = 'firebase' | 'admin' | 'public';

/**
 * A verified caller. Every field is derived from a signature-checked token —
 * nothing here was asserted by the client.
 *
 * `uid` is the Firebase UID, which is what `public.users.id` stores and what
 * every ownership check in this codebase compares against. Note this is NOT a
 * Supabase Auth UUID: see admin/auth/auth-identity.ts for why the two must
 * never be mixed.
 */
export interface AuthenticatedIdentity {
  readonly uid: string;
  readonly email?: string;
  readonly phoneNumber?: string;
  /** Token expiry, epoch seconds. Used to bound how long a cache entry lives. */
  readonly expiresAt: number;
  /** When the user actually authenticated, epoch seconds. */
  readonly authTime?: number;
}

/**
 * Why a request has no proven identity.
 *
 * The distinction that earns this type is `unavailable` versus everything
 * else. A bad token is the CALLER's problem and deserves a 401. Firebase being
 * unreachable is OUR problem and must not be reported as "your credentials are
 * wrong" — that would send a user to re-authenticate over an outage they
 * cannot fix, and would make every one of them do it at the same moment.
 */
export type AuthFailureReason =
  /** No Authorization header, or not a Bearer scheme. */
  | 'absent'
  /** Bearer scheme present but the token is empty or structurally not a JWT. */
  | 'malformed'
  /** Signature and issuer are good; `exp` has passed. The client should refresh. */
  | 'expired'
  /** The token was explicitly revoked (session invalidated, password changed). */
  | 'revoked'
  /** Signature, issuer or audience did not check out. Forged or foreign token. */
  | 'invalid'
  /** We could not decide — Firebase is unconfigured or unreachable. NOT the caller's fault. */
  | 'unavailable';

/**
 * Machine-readable codes returned in the error body.
 *
 * These exist so the mobile client can act correctly WITHOUT parsing prose.
 * The three behaviours a client needs to tell apart:
 *
 *   TOKEN_EXPIRED      → refresh the token and replay the request once
 *   TOKEN_INVALID /
 *   TOKEN_REVOKED      → the session is dead; sign out and re-authenticate
 *   AUTH_UNAVAILABLE   → back off and retry; do NOT sign the user out
 *
 * Getting that wrong is how an outage turns into a wave of forced sign-outs,
 * so the code is part of the contract and is covered by tests.
 */
export const AUTH_ERROR_CODES = {
  /** No credentials were presented at all. */
  AUTH_REQUIRED: 'AUTH_REQUIRED',
  TOKEN_EXPIRED: 'TOKEN_EXPIRED',
  TOKEN_INVALID: 'TOKEN_INVALID',
  TOKEN_REVOKED: 'TOKEN_REVOKED',
  /** Verification could not be performed. Answered 503, never 401. */
  AUTH_UNAVAILABLE: 'AUTH_UNAVAILABLE',
  /** A body/query field named a different user than the token proves. 403. */
  IDENTITY_CONFLICT: 'IDENTITY_CONFLICT',
} as const;

export type AuthErrorCode = (typeof AUTH_ERROR_CODES)[keyof typeof AUTH_ERROR_CODES];

/**
 * The outcome of one verification attempt. Never throws; always answers.
 *
 * ⚠️ THE DISCRIMINANT IS A STRING, NOT A BOOLEAN `ok`, AND IT HAS TO BE.
 * This project compiles with `strictNullChecks: false` (see tsconfig.json),
 * under which TypeScript does NOT narrow a union on a boolean literal
 * discriminant — `if (result.ok) { … } else { result.reason }` fails to compile,
 * because in the else branch `result` is still the whole union. String literal
 * discriminants narrow correctly under the same settings. Verified against this
 * exact compiler configuration rather than assumed. Do not "simplify" this back
 * to `ok: true | false`.
 */
export type VerificationResult =
  | { readonly outcome: 'verified'; readonly identity: AuthenticatedIdentity; readonly cached: boolean }
  | { readonly outcome: 'failed'; readonly reason: AuthFailureReason; readonly detail?: string };

/**
 * Express request, plus everything the auth layer attaches.
 *
 * `auth` is the pre-existing field name (IdentityMiddleware set it before this
 * phase and RateLimitGuard already reads it) and is preserved exactly, so no
 * consumer of it needs to change.
 */
export interface RequestWithIdentity {
  auth?: AuthenticatedIdentity;
  /** Set when a token was presented and did NOT verify. Absent means no token. */
  authFailure?: { readonly reason: AuthFailureReason; readonly detail?: string };
  /** True once IdentityMiddleware has run — distinguishes "no token" from "not yet resolved". */
  authResolved?: boolean;
}
