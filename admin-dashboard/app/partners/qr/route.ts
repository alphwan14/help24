import { NextResponse } from "next/server";
import { qrSvg } from "@/components/partners/PartnerViews";
import { getSessionUser } from "@/lib/supabase-server";
import { resolvePartnerAccess } from "@/lib/partners/access";

/** The signed-in agent's QR code, as an SVG file to print. */
export async function GET() {
  const user = await getSessionUser();
  if (!user) return new NextResponse("Sign in first", { status: 401 });
  const access = await resolvePartnerAccess(user.id);
  if (!access.ok) return new NextResponse("Not a partner account", { status: 403 });
  return new NextResponse(await qrSvg(access.agent.code), {
    headers: {
      "Content-Type": "image/svg+xml",
      "Content-Disposition": `attachment; filename="help24-${access.agent.code}.svg"`,
      "Cache-Control": "private, no-store",
    },
  });
}
