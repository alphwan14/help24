import { NextResponse, type NextRequest } from "next/server";
import { createServiceClient } from "@/lib/supabase-server";

export const dynamic = "force-dynamic";

/** Per address asking, per server instance: enough for a person, a nuisance for a script. */
const WINDOW_MS = 10 * 60 * 1000;
const MAX_CHECKS = 10;
const recent = new Map<string, number[]>();

function tooMany(key: string, now: number): boolean {
  const hits = (recent.get(key) ?? []).filter((t) => now - t < WINDOW_MS);
  hits.push(now);
  recent.set(key, hits);
  if (recent.size > 5000) recent.clear();
  return hits.length > MAX_CHECKS;
}

/**
 * POST /api/admin/reset-eligibility { email } → { admin: boolean }
 *
 * Asked by the sign-in page before it requests a reset email, so an address
 * with no Help24 admin account is told so and no email is sent. "An admin
 * account" is an active admin_users row — the record the backend grants
 * console access from (deactivated admins are not admins).
 *
 * By the owner's decision (2026-11-04) this answers plainly, which also tells
 * anyone asking whether an address is an admin's. The limit above slows a
 * script down; it does not make the answer secret.
 */
export async function POST(request: NextRequest) {
  const body = (await request.json().catch(() => null)) as { email?: unknown } | null;
  const email = typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
  if (!email || email.length > 320 || !email.includes("@")) {
    return NextResponse.json({ message: "Enter a valid email address." }, { status: 400 });
  }

  const ip = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  if (tooMany(ip, Date.now())) {
    return NextResponse.json({ message: "Too many attempts. Wait a few minutes, then try again." }, { status: 429 });
  }

  const { data, error } = await createServiceClient()
    .from("admin_users")
    .select("id")
    .eq("email", email)
    .eq("active", true)
    .limit(1);
  if (error) {
    console.error("[reset-eligibility] lookup failed:", error.message);
    return NextResponse.json({ message: "We couldn't check that email just now. Try again." }, { status: 503 });
  }
  return NextResponse.json({ admin: (data ?? []).length > 0 }, { headers: { "Cache-Control": "no-store" } });
}
