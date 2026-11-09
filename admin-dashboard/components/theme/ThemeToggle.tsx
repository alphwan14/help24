"use client";

import { useEffect, useState } from "react";
import { THEME_STORAGE_KEY, type ThemeChoice } from "./ThemeScript";

/**
 * Three states, not a switch.
 *
 * A two-state toggle cannot express "follow my machine", which is the default
 * and the option most people actually want — a dashboard someone opens at 8am
 * and again at 10pm should track the OS without being told twice. So there are
 * three: System, Light, Dark.
 *
 * The control renders as a segmented group because the current state has to be
 * READABLE at a glance. A single icon button that cycles makes you click to
 * find out where you are.
 */
const OPTIONS: { value: ThemeChoice; label: string; title: string }[] = [
  { value: "system", label: "Auto", title: "Follow system appearance" },
  { value: "light", label: "Light", title: "Always light" },
  { value: "dark", label: "Dark", title: "Always dark" },
];

function read(): ThemeChoice {
  try {
    const t = localStorage.getItem(THEME_STORAGE_KEY);
    if (t === "light" || t === "dark") return t;
  } catch {
    /* private mode: fall through to system */
  }
  return "system";
}

function apply(choice: ThemeChoice) {
  const root = document.documentElement;
  // "system" REMOVES the attribute rather than setting it to anything. The
  // absence is what hands the decision back to the media query — see
  // ThemeScript.
  if (choice === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", choice);
  try {
    if (choice === "system") localStorage.removeItem(THEME_STORAGE_KEY);
    else localStorage.setItem(THEME_STORAGE_KEY, choice);
  } catch {
    /* the theme still applied; only the memory of it is lost */
  }
}

export function ThemeToggle() {
  // Starts as null so the first render matches the SERVER's output. Reading
  // localStorage during render would make the markup depend on a value the
  // server cannot see, which is a hydration mismatch by construction.
  const [choice, setChoice] = useState<ThemeChoice | null>(null);

  useEffect(() => setChoice(read()), []);

  return (
    <div
      role="radiogroup"
      aria-label="Appearance"
      // Lives in Settings now, on an ordinary surface, so it takes the page's
      // theme tokens (it used the always-dark rail colours in the sidebar).
      className="inline-flex items-center gap-0.5 rounded-lg bg-gray-100 p-0.5 self-start"
    >
      {OPTIONS.map((o) => {
        const active = choice === o.value;
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={active}
            title={o.title}
            onClick={() => {
              apply(o.value);
              setChoice(o.value);
            }}
            className={`rounded-md px-3.5 py-1.5 text-[13px] font-medium transition-colors ${
              active
                ? "bg-surface text-gray-900 shadow-sm"
                : "text-gray-500 hover:text-gray-800"
            }`}
          >
            {o.label}
          </button>
        );
      })}
    </div>
  );
}
