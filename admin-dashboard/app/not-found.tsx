import Link from "next/link";

/**
 * Shared by both hosts — admin.help24.co.ke and partners.help24.co.ke route to
 * the same app — so it says nothing about either. "/" is each site's home:
 * the admin overview, or the partner's own overview.
 */
export default function NotFound() {
  return (
    <main className="min-h-screen bg-page flex items-center justify-center px-4">
      <div className="max-w-sm text-center">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src="/favicon.svg" alt="" className="mx-auto h-12 w-12" />
        <h1 className="mt-5 text-xl font-bold text-gray-900">This page doesn&apos;t exist</h1>
        <p className="mt-2 text-sm text-gray-500">The link may be old or mistyped.</p>
        <Link href="/" className="btn-primary mt-6">
          Go to the home page
        </Link>
      </div>
    </main>
  );
}
