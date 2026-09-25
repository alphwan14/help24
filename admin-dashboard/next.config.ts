/**
 * REGION — see vercel.json, which pins it.
 *
 * `vercel.json` is strict-schema and rejects comment keys, so the reasoning
 * lives here.
 *
 * It was unset, meaning Vercel used the account default (normally iad1, US
 * East), while the Supabase project resolves into an AWS EU range
 * (2a05:d018::/32) — so every server-side query was very likely crossing the
 * Atlantic.
 *
 * The asymmetry is the whole argument for co-location: a page load is ONE hop
 * from the reader to Vercel, but MANY hops from Vercel to Postgres. Put the
 * functions next to the database and the multiplied cost disappears; put them
 * next to the reader and you pay it on every query instead.
 *
 * VERIFY THE VALUE. Supabase Dashboard -> Project Settings -> General shows the
 * region; map it to the nearest Vercel one:
 *   eu-central-1 (Frankfurt) -> fra1     eu-west-1 (Ireland) -> dub1
 *   eu-west-2    (London)    -> lhr1     us-east-1 (Virginia) -> iad1
 *
 * fra1 is set as the EU default. If the project is in Ireland this is still far
 * better than the unpinned US East it replaces — an intra-EU hop rather than a
 * transatlantic one. Keep both properties on the same value.
 */

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
