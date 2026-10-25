/**
 * Start a backend read NOW and await it after the access check.
 *
 * Pages used to await getCurrentAdmin() and only then start their data request,
 * so every page paid two backend round trips back to back. The data request
 * does not depend on the check: the backend authorizes it independently with
 * the same bearer token. So the page starts it first, decides access exactly as
 * before, and only then awaits it — on the denial path the result is simply
 * never read, and nothing protected is rendered.
 *
 * The no-op catch only marks a rejection as handled, so a request discarded on
 * the denial path never surfaces as an unhandledRejection. Awaiting the
 * returned promise still throws the original error, so every page's existing
 * try/catch and notFound() handling is unchanged.
 *
 * Never use this for a request that depends on the admin's ROLE: starting it
 * early would send requests the admin is not allowed to make.
 *
 * Its own module (no `server-only`) so node:test can exercise it.
 */
export function startEarly<T>(promise: Promise<T>): Promise<T> {
  promise.catch(() => {});
  return promise;
}
