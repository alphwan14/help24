/**
 * IDENTITY BINDING — the mechanism that makes this migration non-breaking.
 *
 * THE PROBLEM, STATED PRECISELY
 * -----------------------------
 * Every service in this codebase already performs the correct authorization
 * check. `jobs.service.ts` refuses to approve a completion unless
 * `post.author_user_id === dto.client_user_id`; `campaigns.service.ts` refuses
 * to pause a campaign unless `campaign.owner_user_id === userId`;
 * `disputes.service.ts` routes everything through `assertParticipant`. There is
 * no missing authorization anywhere.
 *
 * The defect is narrower than that, and entirely in the INPUT: the value being
 * compared arrives in the request body, so the caller chooses who they are.
 *
 * WHY THIS MATTERS FOR THE SHAPE OF THE FIX
 * -----------------------------------------
 * It means the fix is not "add authorization to forty endpoints". It is "make
 * one field trustworthy, at one seam, before the handler runs". Bind the
 * verified UID onto the field the service already reads, and every existing
 * check becomes sound with ZERO changes to any service. That is the difference
 * between a migration and a rewrite, and it is why this can ship without
 * touching business logic that is currently correct and well tested.
 *
 * THE THREE CASES
 * ---------------
 *   field absent      → INJECT the verified uid. This is what eventually lets
 *                       the client stop sending identity fields at all, and it
 *                       keeps `requireUserId()`-style guards satisfied.
 *   field == uid      → pass through untouched. The normal case for an updated
 *                       client that still sends the field.
 *   field != uid      → CONFLICT. Someone is acting as someone else. Under
 *                       enforcement this is a 403; before it, a loud log.
 *
 * WHY BINDINGS ARE DECLARED PER ROUTE AND NOT INFERRED FROM FIELD NAMES
 * ---------------------------------------------------------------------
 * A tempting shortcut is to bind every field matching /user_id$/. It is wrong,
 * and dangerously so: `SelectProviderDto` carries BOTH `client_user_id` (the
 * caller) and `provider_id` (the person being selected). Overwriting the second
 * with the caller's uid would let a client assign a job to themselves — an
 * authorization bug INTRODUCED by the authorization layer. Declaring the
 * binding at the route makes the distinction explicit, reviewable, and
 * impossible to get wrong by accident.
 */

/** Where a bound field lives. Route params are not identity and are not bindable. */
export type BindingSource = 'body' | 'query';

export interface IdentityBinding {
  readonly source: BindingSource;
  readonly field: string;
  /**
   * `required` — the route needs an identity, so the field is bound or injected.
   * `optional` — the route is public but personalises when it knows the caller.
   */
  readonly mode: 'required' | 'optional';
}

export type BindingOutcome =
  /** Field was absent; the verified uid was written into it. */
  | { readonly kind: 'injected'; readonly binding: IdentityBinding }
  /** Field was present and already equalled the verified uid. */
  | { readonly kind: 'matched'; readonly binding: IdentityBinding }
  /** Field was present and named someone else. */
  | { readonly kind: 'conflict'; readonly binding: IdentityBinding; readonly claimed: string }
  /** Anonymous caller on a public route: an unprovable claim was removed. */
  | { readonly kind: 'dropped'; readonly binding: IdentityBinding; readonly claimed: string }
  /** Anonymous caller, nothing to do. */
  | { readonly kind: 'skipped'; readonly binding: IdentityBinding };

const BINDING_PATH = /^(body|query)\.([A-Za-z_][A-Za-z0-9_]*)$/;

/**
 * Parse `'body.client_user_id'` into a binding.
 *
 * Throws on a malformed path. Called from the decorator at module load, so a
 * typo fails the boot rather than silently binding nothing — the same
 * fail-at-load discipline `@RateLimit` uses for unknown policy names, and for
 * the same reason: a binding that quietly does nothing looks exactly like a
 * binding that works.
 */
export function parseBinding(path: string, mode: IdentityBinding['mode']): IdentityBinding {
  const match = BINDING_PATH.exec(path.trim());
  if (!match) {
    throw new Error(
      `[Auth] Invalid identity binding "${path}". Expected "body.<field>" or ` +
        `"query.<field>" — e.g. "body.client_user_id".`,
    );
  }
  return { source: match[1] as BindingSource, field: match[2], mode };
}

/** A request's mutable body/query bags. Narrowed to what binding needs. */
export interface BindableRequest {
  body?: unknown;
  query?: unknown;
}

/**
 * Apply every binding for this route and report what happened.
 *
 * MUTATES `req.body` / `req.query` IN PLACE, deliberately. Both are plain
 * objects on Express 4 by the time guards run (verified empirically against
 * the installed version, not assumed), and in-place mutation is what makes the
 * change invisible to the ValidationPipe that runs next and to the handler
 * that reads the DTO — which is the whole point: the service sees a normal
 * field containing a now-trustworthy value.
 *
 * `uid` of null means an anonymous caller.
 */
export function applyBindings(
  req: BindableRequest,
  uid: string | null,
  bindings: readonly IdentityBinding[],
  options: { readonly enforcing: boolean },
): BindingOutcome[] {
  const outcomes: BindingOutcome[] = [];

  for (const binding of bindings) {
    const bag = bagFor(req, binding.source);
    // A body that is absent, an array, or a string (text/plain) has no named
    // field to bind. Nothing to do, and never a reason to throw on the request
    // path — the ValidationPipe will reject a malformed body on its own terms.
    if (!bag) {
      outcomes.push({ kind: 'skipped', binding });
      continue;
    }

    const claimed = readString(bag[binding.field]);

    if (uid === null) {
      // Anonymous. On a public+personalised route an unprovable claim is worse
      // than no claim: honouring it lets anyone request another person's
      // personalised ranking simply by naming them. Under enforcement it is
      // removed; before enforcement it is left alone, because removing it would
      // silently de-personalise the shipped client — a behaviour change this
      // stage has promised not to make.
      if (claimed !== null && options.enforcing) {
        delete bag[binding.field];
        outcomes.push({ kind: 'dropped', binding, claimed });
      } else {
        outcomes.push({ kind: 'skipped', binding });
      }
      continue;
    }

    if (claimed === null) {
      bag[binding.field] = uid;
      outcomes.push({ kind: 'injected', binding });
      continue;
    }

    if (claimed === uid) {
      outcomes.push({ kind: 'matched', binding });
      continue;
    }

    outcomes.push({ kind: 'conflict', binding, claimed });
  }

  return outcomes;
}

/**
 * Overwrite conflicting fields with the verified uid.
 *
 * Called only when a conflict is NOT being rejected — that is, in `off` and
 * `monitor` mode. It is what keeps those stages safe rather than merely
 * observant: the request proceeds, so nothing breaks, but it proceeds as the
 * person the token proves rather than the person the body claimed. An attacker
 * who forges a body field while holding a valid token gains nothing even
 * before enforcement is switched on.
 */
export function resolveConflictsToVerified(
  req: BindableRequest,
  uid: string,
  outcomes: readonly BindingOutcome[],
): void {
  for (const outcome of outcomes) {
    if (outcome.kind !== 'conflict') continue;
    const bag = bagFor(req, outcome.binding.source);
    if (bag) bag[outcome.binding.field] = uid;
  }
}

export function conflictsIn(outcomes: readonly BindingOutcome[]): Extract<BindingOutcome, { kind: 'conflict' }>[] {
  return outcomes.filter(
    (o): o is Extract<BindingOutcome, { kind: 'conflict' }> => o.kind === 'conflict',
  );
}

/** Human-readable summary for a log line, e.g. `body.user_id=conflict(abc→xyz)`. */
export function describeOutcomes(outcomes: readonly BindingOutcome[]): string {
  if (outcomes.length === 0) return 'none';
  return outcomes
    .map((o) => {
      const path = `${o.binding.source}.${o.binding.field}`;
      if (o.kind === 'conflict') return `${path}=conflict(claimed=${o.claimed})`;
      if (o.kind === 'dropped') return `${path}=dropped(claimed=${o.claimed})`;
      return `${path}=${o.kind}`;
    })
    .join(' ');
}

function bagFor(req: BindableRequest, source: BindingSource): Record<string, unknown> | null {
  const value = source === 'body' ? req.body : req.query;
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function readString(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed === '' ? null : trimmed;
}
