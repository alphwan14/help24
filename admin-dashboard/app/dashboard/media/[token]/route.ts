import { openMediaToken } from "@/lib/media-link";

/**
 * A photo or document from Storage, served under the console's own address
 * (lib/media-link.ts). Middleware has already required an admin session: the
 * route lives under /dashboard.
 */
export const dynamic = "force-dynamic";

export async function GET(_request: Request, { params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const url = openMediaToken(token);
  if (!url) return new Response("Not found", { status: 404 });

  let upstream: Response;
  try {
    upstream = await fetch(url, { cache: "no-store" });
  } catch {
    return new Response("This file could not be loaded. Reload the page to try again.", { status: 502 });
  }
  // A signed link lasts an hour; after that Storage refuses it. Say so plainly.
  if (!upstream.ok || !upstream.body) {
    return new Response("This link has expired. Reload the page for a fresh one.", {
      status: upstream.status === 404 ? 404 : 410,
    });
  }

  const headers = new Headers({
    "Content-Type": upstream.headers.get("content-type") ?? "application/octet-stream",
    "Cache-Control": "private, max-age=600",
    "Content-Disposition": "inline",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  const length = upstream.headers.get("content-length");
  if (length) headers.set("Content-Length", length);
  return new Response(upstream.body, { status: 200, headers });
}
