"use client";

import { useState, useCallback } from "react";
import { updateUserRole } from "./actions";

interface Props {
  userId: string;
  userEmail: string;
  initialRole: string;
  currentUserEmail: string;
}

interface Toast {
  message: string;
  type: "success" | "error";
}

export function RoleToggle({ userId, userEmail, initialRole, currentUserEmail }: Props) {
  const [role, setRole] = useState(initialRole);
  const [loading, setLoading] = useState(false);
  const [toast, setToast] = useState<Toast | null>(null);

  const isSelf = currentUserEmail.toLowerCase() === userEmail.toLowerCase();
  const isAdmin = role === "admin";

  const showToast = useCallback((message: string, type: Toast["type"]) => {
    setToast({ message, type });
    setTimeout(() => setToast(null), 3500);
  }, []);

  async function handleToggle() {
    if (isSelf || loading) return;
    setLoading(true);

    const newRole = isAdmin ? "user" : "admin";
    const result = await updateUserRole(userId, newRole);

    if (result.ok) {
      setRole(newRole);
      showToast(
        newRole === "admin"
          ? `${userEmail} promoted to admin.`
          : `Admin rights removed from ${userEmail}.`,
        "success"
      );
    } else {
      showToast(result.message, "error");
    }

    setLoading(false);
  }

  return (
    <div className="relative flex items-center gap-2">
      {/* Role badge */}
      <span
        className={`badge ${
          isAdmin ? "bg-brand-100 text-brand-700" : "bg-gray-100 text-gray-500"
        }`}
      >
        {isAdmin ? "Admin" : "User"}
      </span>

      {/* Action button */}
      {isSelf ? (
        <span
          title="You cannot remove your own admin access"
          className="text-xs text-gray-300 cursor-not-allowed select-none"
        >
          {isAdmin ? "Remove Admin" : "Make Admin"}
        </span>
      ) : (
        <button
          onClick={handleToggle}
          disabled={loading}
          /*
           * A QUIET TEXT ACTION, NOT A BUTTON ON EVERY ROW.
           *
           * This was a bordered button rendered once per user, so a table of
           * eighteen people carried eighteen identical outlined controls down
           * its right edge — the loudest column on the page, for an action
           * almost no row will ever take. It also gave PROMOTE TO ADMIN the
           * same visual weight as reading a phone number.
           *
           * The action is unchanged and still one click; it simply stops
           * competing with the data. Removing admin keeps the critical tone,
           * because that one is worth hesitating over.
           */
          className={`text-xs font-medium px-1.5 py-1 rounded transition-colors disabled:opacity-40 ${
            isAdmin
              ? "text-critical-600 hover:bg-critical-50"
              : "text-gray-500 hover:text-gray-900 hover:bg-gray-100"
          }`}
        >
          {loading ? "…" : isAdmin ? "Remove Admin" : "Make Admin"}
        </button>
      )}

      {/* Inline toast */}
      {toast && (
        <div
          className={`fixed bottom-5 right-5 z-50 px-4 py-3 rounded-lg shadow-lg text-sm font-medium flex items-center gap-2 animate-fade-in ${
            toast.type === "success"
              ? "bg-positive-100 text-positive-700 border border-positive-300"
              : "bg-critical-100 text-critical-700 border border-critical-300"
          }`}
        >
          <span>{toast.type === "success" ? "✓" : "✕"}</span>
          {toast.message}
        </div>
      )}
    </div>
  );
}
