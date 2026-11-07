"use client";

import { useEffect, useRef, useState } from "react";
import { preload } from "react-dom";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import {
  GOOGLE_CLIENT_ID,
  GOOGLE_GSI_SRC,
  idTokenError,
  makeNonce,
  type GoogleSignInError,
} from "@/lib/google-sign-in";

type GoogleId = {
  initialize(options: {
    client_id: string;
    nonce: string;
    callback: (response: { credential: string }) => void;
    ux_mode?: "popup";
    context?: "signin";
    itp_support?: boolean;
  }): void;
  renderButton(parent: HTMLElement, options: Record<string, unknown>): void;
};

declare global {
  interface Window {
    google?: { accounts?: { id?: GoogleId } };
  }
}

export type GoogleResult = { ok: true } | { ok: false; error: GoogleSignInError };

/**
 * Whether Google sign-in is switched on in Supabase, from its public settings.
 * Until it is, nothing renders: a token Supabase would refuse is no use.
 */
async function googleEnabled(): Promise<boolean> {
  try {
    const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/auth/v1/settings`, {
      headers: { apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY! },
    });
    const body = (await res.json()) as { external?: { google?: boolean } };
    return res.ok && body.external?.google === true;
  } catch {
    return false;
  }
}

let gisScript: Promise<GoogleId> | null = null;

/** Google's script, loaded once per page; rejects if it cannot be fetched (blocked, offline). */
function loadGoogleId(): Promise<GoogleId> {
  if (window.google?.accounts?.id) return Promise.resolve(window.google.accounts.id);
  gisScript ??= new Promise<GoogleId>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = GOOGLE_GSI_SRC;
    script.async = true;
    script.onload = () => (window.google?.accounts?.id ? resolve(window.google.accounts.id) : reject(new Error("no google.accounts.id")));
    script.onerror = () => reject(new Error("Google's sign-in script did not load"));
    document.head.appendChild(script);
  }).catch((e) => {
    gisScript = null;
    throw e;
  });
  return gisScript;
}

/** The page's effective theme: an explicit choice on <html>, else the system's. */
function isDark(): boolean {
  const chosen = document.documentElement.getAttribute("data-theme");
  if (chosen) return chosen === "dark";
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

/** Google's "G", in its four brand colours, for the placeholder. */
function GoogleMark() {
  return (
    <svg viewBox="0 0 48 48" width="18" height="18" aria-hidden="true">
      <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
      <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
      <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
      <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
    </svg>
  );
}

/**
 * Google's own "Continue with Google" button (Google Identity Services), then
 * Supabase, then the admin gate — see lib/google-sign-in.ts.
 *
 * The page must not shift when it arrives. So from the first paint this
 * reserves the exact space with a stand-in drawn like Google's large button
 * (outline in light, filled black in dark), and Google's real button is drawn
 * ON TOP of it the moment it is ready — the swap is not visible. Google's
 * script is requested during the first render (`preload`), and the three
 * things the button needs — Google switched on in Supabase, the script, a
 * nonce — are fetched at the same time, not one after another.
 *
 * If Google turns out to be off in Supabase, or its script cannot load
 * (blocked, offline), the stand-in is removed and the page is email and
 * password only. `onDone` reports the outcome; the page navigates on success
 * and shows the message otherwise.
 */
export default function GoogleButton({
  onBusy,
  onDone,
}: {
  onBusy: (busy: boolean) => void;
  onDone: (result: GoogleResult) => void;
}) {
  preload(GOOGLE_GSI_SRC, { as: "script" });
  const slot = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<"loading" | "ready" | "off">("loading");
  // The latest handlers, so Google's callback (registered once) never calls a stale one.
  const handlers = useRef({ onBusy, onDone });
  handlers.current = { onBusy, onDone };

  useEffect(() => {
    let live = true;
    void (async () => {
      const [enabled, google, nonce] = await Promise.all([
        googleEnabled(),
        loadGoogleId().catch(() => null),
        makeNonce(),
      ]);
      if (!live) return;
      if (!enabled || !google || !slot.current) {
        setState("off");
        return;
      }

      google.initialize({
        client_id: GOOGLE_CLIENT_ID,
        nonce: nonce.hashed,
        ux_mode: "popup",
        context: "signin",
        itp_support: true,
        callback: async ({ credential }) => {
          const { onBusy: busy, onDone: done } = handlers.current;
          busy(true);
          const { error } = await getSupabaseBrowser().auth.signInWithIdToken({
            provider: "google",
            token: credential,
            nonce: nonce.raw,
          });
          if (error) {
            busy(false);
            done({ ok: false, error: idTokenError(error) });
            return;
          }
          const verdict = (await fetch("/api/admin/google-check", { method: "POST" })
            .then((r) => r.json())
            .catch(() => ({ ok: false, error: "google-failed" }))) as GoogleResult;
          if (!verdict.ok) busy(false);
          done(verdict);
        },
      });
      google.renderButton(slot.current, {
        type: "standard",
        theme: isDark() ? "filled_black" : "outline",
        size: "large",
        text: "continue_with",
        shape: "rectangular",
        logo_alignment: "center",
        width: Math.max(200, Math.min(400, slot.current.offsetWidth)),
      });
      setState("ready");
    })();
    return () => {
      live = false;
    };
  }, []);

  if (state === "off") return null;

  return (
    <div className="space-y-5">
      {/* 40 px: the height of Google's "large" button, so nothing moves when it lands. */}
      <div className="relative mx-auto h-10 w-full max-w-[400px]">
        <div
          aria-hidden="true"
          className="gsi-placeholder pointer-events-none absolute inset-0 flex items-center justify-center gap-2.5 rounded text-sm font-medium"
        >
          <GoogleMark />
          Continue with Google
        </div>
        <div
          ref={slot}
          className="absolute inset-0 flex justify-center"
          data-testid="google-button"
          aria-busy={state === "loading"}
        />
      </div>
      <div className="flex items-center gap-3 text-xs text-gray-400" aria-hidden="true">
        <span className="h-px flex-1 bg-gray-200" />
        or
        <span className="h-px flex-1 bg-gray-200" />
      </div>
    </div>
  );
}
