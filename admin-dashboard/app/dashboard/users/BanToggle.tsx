"use client";

import { useState } from "react";
import { getSupabaseBrowser } from "@/lib/supabase-browser";

export function BanToggle({ userId, isBanned }: { userId: string; isBanned: boolean }) {
  const [banned, setBanned] = useState(isBanned);
  const [loading, setLoading] = useState(false);

  async function toggle() {
    setLoading(true);
    const next = !banned;
    // is_banned column — add via migration if not present
    await getSupabaseBrowser()
      .from("users")
      .update({ is_banned: next } as Record<string, unknown>)
      .eq("id", userId);
    setBanned(next);
    setLoading(false);
  }

  return (
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
  );
}
