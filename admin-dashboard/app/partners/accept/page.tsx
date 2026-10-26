import AcceptForm from "./AcceptForm";
import { hashInviteToken } from "@/lib/partners/rules";
import { createServiceClient } from "@/lib/supabase-server";

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

  return (
    <main className="mx-auto max-w-sm px-4 py-16">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src="/favicon.svg" alt="" className="h-12 w-12" />
      {preview?.valid ? (
        <>
          <h1 className="mt-5 text-2xl font-bold text-gray-900">Welcome, {preview.name}</h1>
          <p className="mt-1 text-sm text-gray-500">
            Choose a password for your Help24 partner account. You&apos;ll sign in with <strong>{preview.email}</strong>.
          </p>
          <AcceptForm token={token} email={preview.email ?? ""} />
        </>
      ) : (
        <>
          <h1 className="mt-5 text-2xl font-bold text-gray-900">This invitation can&apos;t be used</h1>
          <p className="mt-2 text-sm text-gray-500">
            It has expired, was already used, or the link is incomplete. Ask Help24 for a new invitation.
          </p>
        </>
      )}
    </main>
  );
}
