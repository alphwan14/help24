import Link from "next/link";
import AuthShell from "@/components/auth/AuthShell";
import { PartnerPreview } from "@/components/auth/ConsolePreviews";
import { PARTNER_HELP } from "@/lib/auth-audiences";
import { hashInviteToken } from "@/lib/partners/rules";
import { createServiceClient } from "@/lib/supabase-server";
import AcceptForm from "./AcceptForm";

export const dynamic = "force-dynamic";

/** An invitation: shows who it is for, then asks only for a password. */
export default async function PartnerAcceptPage({ searchParams }: { searchParams: Promise<{ token?: string }> }) {
  const { token = "" } = await searchParams;
  const valid = /^[A-Za-z0-9_-]{43}$/.test(token);
  const preview = valid
    ? ((await createServiceClient().rpc("partner_invite_preview", { p_token_hash: await hashInviteToken(token) })).data as
        | { valid: boolean; email?: string; name?: string }
        | null)
    : null;

  if (!preview?.valid) {
    return (
      <AuthShell
        product="Help24 Partners"
        preview={<PartnerPreview />}
        help={PARTNER_HELP}
        title="This invitation can't be used"
        subtitle="It has expired, was already used, or the link is incomplete. Ask Help24 for a new invitation."
      >
        <Link href="/login" className="btn-ghost border border-gray-200 w-full">
          I already have a password — sign in
        </Link>
      </AuthShell>
    );
  }

  return (
    <AuthShell
      product="Help24 Partners"
      preview={<PartnerPreview />}
      help={PARTNER_HELP}
      title={`Welcome to Help24 Partners, ${preview.name?.split(/\s+/)[0] ?? "partner"}`}
      subtitle={
        <>
          Choose a password to finish setting up your account. You&apos;ll sign in with{" "}
          <strong className="font-semibold text-gray-800">{preview.email}</strong>.
        </>
      }
    >
      <AcceptForm token={token} email={preview.email ?? ""} />
    </AuthShell>
  );
}
