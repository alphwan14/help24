import { SetMetadata } from '@nestjs/common';
import { IdentityBinding, parseBinding } from './identity-binding';
import { AuthScheme } from './auth.types';

export const AUTH_SPEC_KEY = 'help24:authSpec';

/**
 * What a route declares about who may call it.
 *
 * Attached by decorator rather than held in a central path table, for the
 * reason `@RateLimit` documents: a table binds by string, so renaming a route
 * silently drops its protection and nothing fails at compile time or at boot.
 * A decorator travels with the handler and cannot be orphaned.
 */
export interface AuthSpec {
  readonly scheme: AuthScheme;
  readonly bindings: readonly IdentityBinding[];
  /** Why this route is public. Required for `@Public` — see below. */
  readonly reason?: string;
}

/**
 * Require a verified Firebase identity, and bind it onto the named fields.
 *
 *   @Auth('body.client_user_id')
 *   @Post('approve')
 *   approve(@Body() dto: ApproveDto) { … }
 *
 * Each argument names the field that carries THE CALLER's identity — the one
 * the service compares against a resource owner. After the guard runs, that
 * field is guaranteed to hold a UID proven by a signed token, so the existing
 * ownership check in the service becomes sound without being modified.
 *
 * Name only fields that mean "the person making this request". A field naming
 * someone ELSE — `provider_id` in select-provider, the provider being chosen —
 * must NOT be listed: binding it would let a caller assign the job to
 * themselves. See identity-binding.ts.
 *
 * `@Auth()` with no arguments is valid and means "a verified identity is
 * required, and nothing in the payload needs rewriting".
 *
 * THE BOUND FIELD MUST EXIST ON THE DTO. The global ValidationPipe runs with
 * `forbidNonWhitelisted: true`, so injecting a field the DTO does not declare
 * would turn into a 400. Guards run before pipes, which is what makes the
 * injection visible to validation in the first place — and what makes this
 * constraint real. `auth.contract.spec.ts` checks every binding against its DTO.
 */
export const Auth = (...bindings: string[]): MethodDecorator & ClassDecorator =>
  SetMetadata(AUTH_SPEC_KEY, {
    scheme: 'firebase',
    bindings: bindings.map((path) => parseBinding(path, 'required')),
  } satisfies AuthSpec);

/**
 * No identity required.
 *
 * THE REASON IS MANDATORY, and that is not ceremony. Every public route on a
 * marketplace that moves money is a decision someone made, and six months later
 * the only question that matters about it is "was this deliberate?". A required
 * string makes the answer readable at the call site instead of reconstructible
 * from a commit log. The boot-time route audit prints these reasons, so the
 * full public surface of the API can be reviewed in one screen of output.
 *
 * `bind` handles the public-but-personalised case — `GET /feed` is the example.
 * Anonymous browsing keeps working exactly as it does today; when a token IS
 * present the caller's own uid is bound, so a signed-in user can no longer be
 * handed someone else's personalised ranking by naming them in the query.
 */
export const Public = (
  reason: string,
  options?: { readonly bind?: string | readonly string[] },
): MethodDecorator & ClassDecorator => {
  if (!reason?.trim()) {
    throw new Error(
      '[Auth] @Public() requires a reason explaining why this route needs no ' +
        'identity. It is printed in the boot-time route audit.',
    );
  }
  const paths = options?.bind === undefined ? [] : normalise(options.bind);
  return SetMetadata(AUTH_SPEC_KEY, {
    scheme: 'public',
    reason: reason.trim(),
    bindings: paths.map((path) => parseBinding(path, 'optional')),
  } satisfies AuthSpec);
};

/**
 * This route is protected by the opaque Help24 admin token, not by Firebase.
 *
 * The Firebase guard stands down entirely; AdminAuthGuard does the work. This
 * decorator is therefore a DECLARATION rather than an enforcement — which is
 * exactly why the boot-time audit cross-checks it against the actual
 * `@UseGuards(AdminAuthGuard)` on the controller and fails loudly when the two
 * disagree.
 *
 * That check is not hypothetical. `/admin/events/*` shipped with an
 * `@RateLimit('admin:api')` decorator and no guard at all, leaving event
 * listing and `POST /admin/events/replay` — which re-runs payout handlers —
 * open to anyone who knew the path. Every other admin controller was guarded,
 * so the mistake was invisible to review. An automated cross-check is the only
 * thing that reliably catches a missing guard.
 */
export const AdminAuth = (): MethodDecorator & ClassDecorator =>
  SetMetadata(AUTH_SPEC_KEY, { scheme: 'admin', bindings: [] } satisfies AuthSpec);

function normalise(value: string | readonly string[]): readonly string[] {
  return typeof value === 'string' ? [value] : value;
}
