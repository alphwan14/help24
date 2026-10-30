import Image from "next/image";

/**
 * The frame every sign-in page sits in — admin.help24.co.ke and
 * partners.help24.co.ke alike.
 *
 * The convention every serious console follows (Google, Microsoft, AWS,
 * Stripe, GitHub): one centred card, the mark, "Sign in", a quiet "to
 * continue to …", the form — and NOTHING about what is behind it. A sign-in
 * page is public, so it must not describe how the console is organised: no
 * section names, no layout, no figures. The impression comes from craft —
 * spacing, type, a soft brand-tinted ground, both themes — not from content.
 */

export default function AuthShell({
  product,
  title,
  subtitle,
  children,
  below,
  notice,
  help,
}: {
  /** "Help24 Operations", "Help24 Partners". */
  product: string;
  title: string;
  /** Defaults to "to continue to {product}". */
  subtitle?: React.ReactNode;
  children: React.ReactNode;
  /** One quiet line inside the card, under the form. */
  below?: React.ReactNode;
  /** The trust line under the card, e.g. "Authorised Help24 staff only". */
  notice: string;
  /** Who to ask when signing in does not work (the footer). */
  help: React.ReactNode;
}) {
  return (
    <div className="relative min-h-screen overflow-hidden bg-page flex flex-col">
      {/* A soft amber light from above — the brand's accent, at a strength
          that tints the ground without becoming a picture. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-x-0 top-0 h-[520px]"
        // The token follows the theme: a warm wash in light, a faint one in dark.
        style={{ background: "radial-gradient(ellipse 60% 55% at 50% 0%, rgb(var(--caution-100-rgb) / 0.75), transparent 70%)" }}
      />

      <main className="relative flex flex-1 items-center justify-center px-4 py-12">
        <div className="w-full max-w-[400px]">
          <div className="rounded-2xl border border-gray-200 bg-surface px-7 py-9 sm:px-9 shadow-[0_1px_2px_rgba(16,24,40,0.04),0_24px_48px_-16px_rgba(16,24,40,0.18)]">
            <Image src="/help24.png" alt="Help24" width={44} height={44} priority />
            <h1 className="mt-6 text-[24px] font-bold tracking-tight text-gray-900">{title}</h1>
            <p className="mt-1 text-[14px] text-gray-500">{subtitle ?? <>to continue to {product}</>}</p>
            <div className="mt-7">{children}</div>
            {below && <div className="mt-6 border-t border-gray-100 pt-5 text-[12.5px] leading-relaxed text-gray-500">{below}</div>}
          </div>
          <p className="mt-5 flex items-center justify-center gap-1.5 text-[12px] text-gray-400">
            <svg viewBox="0 0 20 20" fill="currentColor" className="h-3.5 w-3.5" aria-hidden>
              <path
                fillRule="evenodd"
                d="M10 1a4.5 4.5 0 00-4.5 4.5V9H5a2 2 0 00-2 2v6a2 2 0 002 2h10a2 2 0 002-2v-6a2 2 0 00-2-2h-.5V5.5A4.5 4.5 0 0010 1zm3 8V5.5a3 3 0 10-6 0V9h6z"
                clipRule="evenodd"
              />
            </svg>
            {notice}
          </p>
        </div>
      </main>

      <footer className="relative px-4 pb-6 text-center text-[12px] text-gray-400">
        <span>© {new Date().getFullYear()} Help24</span>
        <span className="mx-2">·</span>
        <a href="https://help24.co.ke/privacy" className="hover:text-gray-700 hover:underline underline-offset-2">Privacy</a>
        <span className="mx-2">·</span>
        <a href="https://help24.co.ke/terms" className="hover:text-gray-700 hover:underline underline-offset-2">Terms</a>
        <span className="mx-2">·</span>
        {help}
      </footer>
    </div>
  );
}
