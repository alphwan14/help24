import { NextResponse } from "next/server";
import { getCurrentAdmin } from "@/lib/api";

export const dynamic = "force-dynamic";

/**
 * GET /api/admin/identity
 *
 * Resolves the arbitration bearer token stored in the h24_admin_token httpOnly
 * cookie and returns the identity it represents. Called client-side from the
 * Sidebar for mismatch detection; the cookie is never exposed to JS.
 *
 * Returns { connected: false } on any failure (no cookie, bad token, backend
 * unreachable) — the Sidebar treats that as "No arbitration access".
 */
export async function GET() {
  try {
    const admin = await getCurrentAdmin();
    if (!admin) {
      return NextResponse.json({ connected: false });
    }
    return NextResponse.json({
      connected: true,
      email: admin.email,
      name: admin.name,
      role: admin.role,
    });
  } catch {
    return NextResponse.json({ connected: false });
  }
}
