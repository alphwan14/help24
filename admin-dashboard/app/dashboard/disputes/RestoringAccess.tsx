"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { restoreArbitration } from "@/lib/arbitration-client";
import ConnectAccess from "./ConnectAccess";

type Phase = "restoring" | "recovery";

/**
 * Arbitration gate shown when a server page found no connected admin. Instead of
 * immediately asking the user to reconnect, it FIRST tries to silently restore
 * access from the authenticated Supabase session (the normal case after login or
 * a cookie expiry). Only if that genuinely fails — no admin record, inactive,
 * revoked — does it fall back to the recovery screen.
 *
 * So during ordinary login/onboarding the user sees a brief "restoring" moment
 * and then their content, never a reconnect prompt.
 */
export default function RestoringAccess() {
  const router = useRouter();
  const [phase, setPhase] = useState<Phase>("restoring");
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;

    void (async () => {
      const data = await restoreArbitration();
      if (data.connected) {
        // Cookie is now set — re-render the server page with live data.
        router.refresh();
        return;
      }
      setPhase("recovery");
    })();
  }, [router]);

  if (phase === "recovery") {
    return <ConnectAccess />;
  }

  return (
    <div className="max-w-md mx-auto">
      <div className="card p-8 text-center space-y-4">
        <div className="mx-auto w-10 h-10 rounded-full border-2 border-brand-200 border-t-brand-600 animate-spin" />
        <div>
          <h2 className="text-base font-bold text-gray-900">Getting things ready</h2>
          <p className="text-sm text-gray-500 mt-1">
            Restoring your access — just a moment…
          </p>
        </div>
      </div>
    </div>
  );
}
