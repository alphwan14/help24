import { NextResponse } from "next/server";
import { createSessionWriter } from "@/lib/supabase-server";

/**
 * POST /signout on the partner host: end the session, back to sign-in.
 * The Location is relative on purpose: behind the middleware rewrite,
 * request.url can carry the server's own host rather than the partner host,
 * and an absolute redirect built from it lands on the admin site.
 */
export async function POST() {
  const supabase = await createSessionWriter();
  await supabase.auth.signOut();
  return new NextResponse(null, { status: 303, headers: { Location: "/login" } });
}
