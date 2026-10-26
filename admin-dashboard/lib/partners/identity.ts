import "server-only";
import { redirect } from "next/navigation";
import { getSessionUser } from "../supabase-server";
import { resolvePartnerAccess, type PartnerAgent } from "./access";

export type { PartnerAgent } from "./access";

/**
 * The signed-in partner, or a redirect to the portal's sign-in. Middleware
 * has already refused anyone else; this re-checks for the page itself and
 * returns the agent it may show.
 */
export async function requirePartner(): Promise<PartnerAgent> {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  const access = await resolvePartnerAccess(user.id);
  if (!access.ok) redirect(`/login?error=${access.reason}`);
  return access.agent;
}
