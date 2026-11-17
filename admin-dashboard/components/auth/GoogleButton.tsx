"use client";

import { useEffect, useRef, useState } from "react";
import { preload } from "react-dom";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import type { ArbitrationIdentity } from "@/lib/arbitration-client";
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

export type GoogleResult =
  | { ok: true; identity?: ArbitrationIdentity }
  | { ok: false; error: GoogleSignInError };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The last answer from Supabase, so one slow or failed check never hides the button. */
const ENABLED_KEY = "h24_google_signin";

/**
 * Whether Google sign-in is switched on in Supabase, from its public settings.
 *
 * Only a definite "off" hides the button. The button used to vanish whenever
 * this one request failed or was slow to answer (often the first load after
 * signing out), and came back only on a refresh. Now a failed check is retried,
 * and if it still cannot answer, the last known answer stands (on, by default):
 * if Google really were off, Supabase would refuse the sign-in and the page
 * would say so.
 */
async function googleEnabled(): Promise<boolean> {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/auth/v1/settings`, {
        headers: { apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY! },
        cache: "no-store",
      });
      if (res.ok) {
        const body = (await res.json()) as { external?: { google?: boolean } };
        const on = body.external?.google === true;
        try {
          localStorage.setItem(ENABLED_KEY, on ? "on" : "off");
        } catch {
          /* private mode */
        }
        return on;
      }
    } catch {
      /* retry below */
    }
    await sleep(500 * (attempt + 1));
  }
  try {
    return localStorage.getItem(ENABLED_KEY) !== "off";
  } catch {
    return true;
  }
}

/**
 * Give Google's token to Supabase. A dropped connection or a Supabase hiccup
 * is retried (the token is good for an hour); a real refusal is not.
 */
async function signInToSupabase(credential: string, nonce: string) {
  const auth = getSupabaseBrowser().auth;
  let result = await auth.signInWithIdToken({ provider: "google", token: credential, nonce });
  for (let attempt = 1; attempt < 3 && result.error && transient(result.error); attempt++) {
    await sleep(500 * attempt);
    result = await auth.signInWithIdToken({ provider: "google", token: credential, nonce });
  }
  if (result.error) console.warn(`[google-sign-in] Supabase refused: ${result.error.code ?? result.error.status ?? ""} ${result.error.message}`);
  return result;
}

function transient(error: { name?: string; status?: number }): boolean {
  return error.name === "AuthRetryableFetchError" || !error.status || error.status >= 500;
}

/**
 * Ask the admin gate, sending the new session's token: the cookie written at
 * the same moment was not always readable by the server yet on a phone, which
 * is what failed the first try. An answer that may be a blip is asked once more.
 */
async function askAdminGate(accessToken: string | undefined): Promise<GoogleResult> {
  let verdict: GoogleResult = { ok: false, error: "google-failed" };
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt) await sleep(700);
    verdict = (await fetch("/api/admin/google-check", {
      method: "POST",
      headers: accessToken ? { Authorization: `Bearer ${accessToken}` } : undefined,
    })
      .then((r) => r.json())
      .catch(() => ({ ok: false, error: "google-failed" }))) as GoogleResult;
    if (verdict.ok || (verdict.error !== "google-failed" && verdict.error !== "unavailable")) break;
  }
  if (!verdict.ok) console.warn(`[google-sign-in] admin check: ${verdict.error}`);
  return verdict;
}

let gisScript: Promise<GoogleId> | null = null;

/** One try at Google's script. Resolves once google.accounts.id exists. */
function loadOnce(): Promise<GoogleId> {
  return new Promise<GoogleId>((resolve, reject) => {
    document.querySelectorAll(`script[data-gsi]`).forEach((el) => el.remove());
    const script = document.createElement("script");
    script.src = GOOGLE_GSI_SRC;
    script.async = true;
    script.dataset.gsi = "1";
    script.onload = async () => {
      // The global can land a tick after onload; give it a moment before failing.
      for (let i = 0; i < 20 && !window.google?.accounts?.id; i++) await sleep(50);
      const id = window.google?.accounts?.id;
      if (id) resolve(id);
      else reject(new Error("no google.accounts.id"));
    };
    script.onerror = () => reject(new Error("Google's sign-in script did not load"));
    document.head.appendChild(script);
  });
}

/** Google's script, loaded once per page and retried twice before giving up
 *  (blocked by an extension, or really offline). */
function loadGoogleId(): Promise<GoogleId> {
  if (window.google?.accounts?.id) return Promise.resolve(window.google.accounts.id);
  gisScript ??= (async () => {
    let last: unknown;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        return await loadOnce();
      } catch (e) {
        last = e;
        await sleep(600 * (attempt + 1));
      }
    }
    throw last;
  })().catch((e) => {
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
        // Say why in the console: this is the only trace when the button is missing.
        console.warn(`[google-sign-in] button hidden: ${!enabled ? "Google is off in Supabase" : !google ? "Google's script did not load" : "no slot"}`);
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
          const { data, error } = await signInToSupabase(credential, nonce.raw);
          if (error) {
            busy(false);
            done({ ok: false, error: idTokenError(error) });
            return;
          }
          const verdict = await askAdminGate(data.session?.access_token);
          if (!verdict.ok) {
            // The server signs a refused session out; make sure this tab is too.
            await getSupabaseBrowser().auth.signOut({ scope: "local" }).catch(() => {});
            busy(false);
          }
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
