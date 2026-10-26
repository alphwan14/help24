"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

/**
 * Re-renders the page's server data every `seconds` while the tab is visible,
 * and once straight away when it becomes visible again. A hidden tab never
 * polls, so a board left open overnight costs nothing.
 */
export default function LiveRefresh({ at, seconds = 30 }: { at: string; seconds?: number }) {
  const router = useRouter();
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const refresh = () => {
      if (document.visibilityState === "visible") router.refresh();
    };
    const poll = setInterval(refresh, seconds * 1000);
    const tick = setInterval(() => setNow(Date.now()), 1000);
    document.addEventListener("visibilitychange", refresh);
    return () => {
      clearInterval(poll);
      clearInterval(tick);
      document.removeEventListener("visibilitychange", refresh);
    };
  }, [router, seconds]);

  const age = Math.max(0, Math.round((now - Date.parse(at)) / 1000));
  return (
    <p className="text-[12px] text-gray-400 font-tabular" aria-live="off">
      <span className="inline-block h-2 w-2 rounded-full bg-positive-500 mr-1.5 align-middle animate-pulse" aria-hidden />
      Updated {age < 5 ? "just now" : `${age}s ago`} · refreshes every {seconds}s
    </p>
  );
}
