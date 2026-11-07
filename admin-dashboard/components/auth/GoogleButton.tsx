"use client";

import { useEffect, useRef, useState } from "react";
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

/**
 * Google's own "Continue with Google" button (Google Identity Services), then
 * Supabase, then the admin gate — see lib/google-sign-in.ts.
 *
 * Renders nothing until Google is on in Supabase and Google's script has
 * loaded, so a blocked script or a provider switched off leaves the page as
 * it was: email and password only. `onDone` reports the outcome; the page
 * navigates on success and shows the message otherwise.
 */
export default function GoogleButton({
  onBusy,
  onDone,
}: {
  onBusy: (busy: boolean) => void;
  onDone: (result: GoogleResult) => void;
}) {
  const slot = useRef<HTMLDivElement>(null);
  const [shown, setShown] = useState(false);
  // The latest handlers, so Google's callback (registered once) never calls a stale one.
  const handlers = useRef({ onBusy, onDone });
  handlers.current = { onBusy, onDone };

  useEffect(() => {
    let live = true;
    void (async () => {
      if (!(await googleEnabled())) return;
      let google: GoogleId;
      try {
        google = await loadGoogleId();
      } catch {
        return;
      }
      const nonce = await makeNonce();
      if (!live || !slot.current) return;

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
        // Measured on the form: this slot is still hidden, so it has no width yet.
        width: Math.max(200, Math.min(400, slot.current.closest("form")?.offsetWidth ?? 320)),
      });
      setShown(true);
    })();
    return () => {
      live = false;
    };
  }, []);

  return (
    <div className={shown ? "space-y-5" : "hidden"}>
      <div ref={slot} className="flex min-h-[44px] w-full justify-center" data-testid="google-button" />
      <div className="flex items-center gap-3 text-xs text-gray-400" aria-hidden="true">
        <span className="h-px flex-1 bg-gray-200" />
        or
        <span className="h-px flex-1 bg-gray-200" />
      </div>
    </div>
  );
}
