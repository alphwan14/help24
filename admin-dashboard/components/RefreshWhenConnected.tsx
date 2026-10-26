"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";

/**
 * Rendered only when the server drew a page without the arbitration record
 * (Settings: name and role; App controls: the live values). That happens when
 * a page loads while the previous page’s shell is still restoring
 * arbitration: the cookie lands after this page’s server render, so the shell
 * here finds it connected and never refreshes. Ask once — the identity check
 * mints nothing — and re-render if the record is there now. Once per mount, so
 * a page that still cannot see it cannot loop.
 */
export default function RefreshWhenConnected() {
  const router = useRouter();
  const asked = useRef(false);

  useEffect(() => {
    if (asked.current) return;
    asked.current = true;
    void fetch("/api/admin/identity")
      .then((r) => r.json() as Promise<{ connected?: boolean }>)
      .then((identity) => {
        if (identity.connected) router.refresh();
      })
      .catch(() => {});
  }, [router]);

  return null;
}
