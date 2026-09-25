import type { NextConfig } from "next";

// Derive the Supabase storage host from the env var instead of hardcoding a
// project ref. Falls back to the generic Supabase wildcard if unset at build.
function supabaseImageHost(): string {
  try {
    return new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").hostname || "*.supabase.co";
  } catch {
    return "*.supabase.co";
  }
}

const nextConfig: NextConfig = {
  images: {
    remotePatterns: [{ protocol: "https", hostname: supabaseImageHost() }],
  },

  /**
   * `next dev` and `next build` both write to `.next`, and a build run while a
   * dev server is serving from it overwrites the module manifest the dev
   * server is holding in memory. The symptom is not a clear one: the page
   * dies with `Could not find the module "…/segment-explorer-node.js" in the
   * React Client Manifest` and `__webpack_modules__[moduleId] is not a
   * function`, both pointing at Next's own devtools internals, which sends you
   * hunting for a bug in framework code rather than in your own workflow.
   *
   * Setting NEXT_DIST_DIR gives a second process somewhere else to write, so a
   * verification build can run against a live dev server instead of demolishing
   * it:
   *
   *     NEXT_DIST_DIR=.next-verify npx next build
   */
  distDir: process.env.NEXT_DIST_DIR || ".next",

  /**
   * Next's dev indicator defaults to the bottom LEFT, which is exactly where
   * this app's sidebar keeps its footer — so in development it sits on top of
   * "Auth debug" and "Sign out" and makes them unclickable. Dev-only, but it
   * obscures the two controls most used while developing.
   */
  devIndicators: {
    position: "bottom-right",
  },
};

export default nextConfig;
