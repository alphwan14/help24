import { NextResponse } from "next/server";
import { ApiError } from "@/lib/api";
import { adminActionRequest } from "@/lib/arbitration-session";
import type { AlertsResponse } from "@/lib/alerts";

export const dynamic = "force-dynamic";

/**
 * GET /api/admin/alerts
 *
 * Proxies GET /admin/alerts with the admin bearer token from the httpOnly
 * cookie — the same arrangement as /api/admin/identity, so the token never
 * reaches client JavaScript. The bell polls this.
 *
 * A failure is returned AS a failure (non-2xx with a message), never as an
 * empty list: "no alerts" and "could not check" are different facts.
 *
 * A refused or missing key is renewed from the Supabase session first
 * (lib/arbitration-session.ts), so the bell's poll also repairs the tab's key.
 */
export async function GET() {
  try {
    const data = await adminActionRequest<AlertsResponse>("/admin/alerts");
    return NextResponse.json(data, { headers: { "Cache-Control": "no-store" } });
  } catch (err) {
    const status = err instanceof ApiError ? err.status : 502;
    const message = err instanceof ApiError ? err.message : "Could not load alerts.";
    return NextResponse.json({ message }, { status: status >= 400 ? status : 502 });
  }
}
