/**
 * One `[sb]` log line per Supabase call made on the server, the counterpart of
 * the `[api]` line `adminRequest` writes per backend call. Together they show
 * in Vercel's runtime logs what each hop costs from the region the functions
 * run in (vercel.json), which is how the fra1 → dub1 move was measured.
 *
 * Method, path WITHOUT its query string, status and duration. Never the query
 * (PostgREST filters carry ids and emails), a header or a body.
 */

/** The line for one call. Pure, so the "no query string" rule is testable. */
export function sbLogLine(method: string, url: string, status: number | string, ms: number): string {
  let path = url;
  try {
    path = new URL(url).pathname;
  } catch {
    path = url.split("?")[0];
  }
  return `[sb] ${method.toUpperCase()} ${path} ${status} ${ms.toFixed(0)}ms`;
}

/** A fetch for supabase-js's `global.fetch` that logs one `[sb]` line per call. */
export const timedFetch: typeof fetch = async (input, init) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  const method = init?.method ?? (input instanceof Request ? input.method : "GET");
  const started = performance.now();
  try {
    const res = await fetch(input, init);
    console.log(sbLogLine(method, url, res.status, performance.now() - started));
    return res;
  } catch (e) {
    console.log(sbLogLine(method, url, "network-error", performance.now() - started));
    throw e;
  }
};
