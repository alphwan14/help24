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
};

export default nextConfig;
