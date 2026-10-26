"use client";

import { useState } from "react";

/** Copies `value`; says so for two seconds. */
export default function CopyButton({ value, label = "Copy", className = "" }: { value: string; label?: string; className?: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      type="button"
      className={`btn-ghost border border-gray-200 ${className}`}
      onClick={() => {
        void navigator.clipboard?.writeText(value).then(() => {
          setDone(true);
          setTimeout(() => setDone(false), 2000);
        });
      }}
    >
      {done ? "Copied ✓" : label}
    </button>
  );
}
