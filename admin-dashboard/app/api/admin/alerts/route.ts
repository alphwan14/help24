import { NextResponse } from "next/server";
import { ApiError, adminRequest, getAdminToken } from "@/lib/api";
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
 */
export async function GET() {
  if (!(await getAdminToken())) {
    return NextResponse.json({ message: "Not connected." }, { status: 401 });
  }
  try {
    const data = await adminRequest<AlertsResponse>("/admin/alerts");
    return NextResponse.json(data, { headers: { "Cache-Control": "no-store" } });
  } catch (err) {
    const status = err instanceof ApiError ? err.status : 502;
    const message = err instanceof ApiError ? err.message : "Could not load alerts.";
    return NextResponse.json({ message }, { status: status >= 400 ? status : 502 });
  }
}
