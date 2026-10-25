import Image from "next/image";
import { parseRecoveryLinkError } from "@/lib/recovery-session";
import ResetPasswordFlow from "./ResetPasswordFlow";

export const dynamic = "force-dynamic";

type PageProps = { searchParams: Promise<{ error?: string }> };

/**
 * Where a password-reset link ends up, after app/auth/callback has traded its
 * code for a recovery session. Public, like /login and /accept-invite: the
 * recovery session is the authorization, and without one the page only offers
 * a new link.
 *
 * The session is read in the browser (ResetPasswordFlow), not here. Middleware
 * does not run on this path, so a server read could refresh the session
 * without being able to write the new tokens back — and a refresh token used
 * twice gets the whole session revoked.
 */
export default async function ResetPasswordPage({ searchParams }: PageProps) {
  const { error } = await searchParams;

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-rail-950 to-rail-900 p-4">
      <div className="w-full max-w-sm">
        <div className="text-center mb-8">
          <Image
            src="/help24.png"
            alt="Help24 logo"
            width={56}
            height={56}
            className="w-14 h-14 mx-auto mb-4"
            priority
          />
          <h1 className="text-2xl font-bold text-rail-50">Help24 Admin</h1>
          <p className="text-rail-200 text-sm mt-1">Choose a new password</p>
        </div>
        <ResetPasswordFlow linkError={parseRecoveryLinkError(error)} />
      </div>
    </div>
  );
}
