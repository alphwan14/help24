"use client";

import { useState } from "react";
import { setUserBanned } from "./actions";

export function BanToggle({ userId, isBanned }: { userId: string; isBanned: boolean }) {
  const [banned, setBanned] = useState(isBanned);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function toggle() {
    setLoading(true);
    setError(null);
    const next = !banned;

    // Server action: the admin check and the write both happen on the server.
    // This component no longer writes to the database directly.
    const result = await setUserBanned(userId, next);

    if (result.ok) {
      setBanned(next);
    } else {
      // A refused change must not look like it applied — the badge stays put
      // and says why.
      setError(result.message);
    }
    setLoading(false);
  }

  return (
    <div className="flex flex-col items-start gap-1">
      <button
        onClick={toggle}
        disabled={loading}
        className={`badge cursor-pointer transition-colors ${
          banned
            ? "bg-red-100 text-red-700 hover:bg-red-200"
            : "bg-green-100 text-green-700 hover:bg-green-200"
        }`}
      >
        {loading ? "…" : banned ? "Banned" : "Active"}
      </button>
      {error && <span className="text-xs text-red-600">{error}</span>}
    </div>
  );
}
