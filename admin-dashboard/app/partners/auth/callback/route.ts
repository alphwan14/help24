// The partner host's /auth/callback: the same handler as the admin console's.
// It redirects by path only, so the partner host keeps its own address.
export const dynamic = "force-dynamic";
export { GET } from "@/app/auth/callback/route";
