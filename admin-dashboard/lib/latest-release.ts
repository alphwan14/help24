import "server-only";

/**
 * The newest published Android release — the version the website's download
 * page serves (help24_website syncs from the same GitHub release). The App
 * controls page uses it to refuse a version gate nobody can satisfy.
 *
 * Cached 10 minutes; null when GitHub cannot be reached, and callers then skip
 * the check rather than guess.
 */
export async function getLatestRelease(): Promise<{ version: string; publishedAt: string } | null> {
  try {
    const res = await fetch("https://api.github.com/repos/alphwan14/help24/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
      next: { revalidate: 600 },
      signal: AbortSignal.timeout(3000),
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { tag_name?: string; published_at?: string };
    const version = String(body.tag_name ?? "").replace(/^v/, "");
    if (!/^\d+\.\d+\.\d+$/.test(version)) return null;
    return { version, publishedAt: String(body.published_at ?? "") };
  } catch {
    return null;
  }
}
