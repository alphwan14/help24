import Image from "next/image";

/**
 * The frame every sign-in page sits in — admin.help24.co.ke and
 * partners.help24.co.ke alike.
 *
 * Desktop: the product itself on the left — a miniature of the console or the
 * partner overview (components/auth/ConsolePreviews.tsx) on the always-dark
 * `rail` panel — and the form on the right. Phone: the form alone, under the
 * mark. No marketing copy: the page says where you are by showing it.
 */

function Mark({ size }: { size: number }) {
  // The mark carries its own squircle, so it sits on either panel with no plate.
  return <Image src="/help24.png" alt="" width={size} height={size} className="shrink-0" priority />;
}

export default function AuthShell({
  product,
  preview,
  title,
  subtitle,
  children,
  below,
  help,
}: {
  /** "Help24 Operations", "Help24 Partners". */
  product: string;
  /** The miniature shown beside the form on desktop. */
  preview: React.ReactNode;
  title: string;
  subtitle?: React.ReactNode;
  children: React.ReactNode;
  /** One quiet line under the form, when there is something to know. */
  below?: React.ReactNode;
  /** Who to ask when signing in does not work. */
  help: React.ReactNode;
}) {
  return (
    <div className="min-h-screen bg-page lg:grid lg:grid-cols-[minmax(0,7fr)_minmax(0,5fr)]">
      <aside className="relative hidden lg:flex flex-col bg-rail-950 px-10 py-9 xl:px-14 overflow-hidden">
        <div className="flex items-center gap-2.5">
          <Mark size={30} />
          <span className="text-[14px] font-semibold tracking-tight text-rail-50">{product}</span>
        </div>
        <div className="flex flex-1 items-center justify-center py-10">{preview}</div>
        <p className="text-[12px] text-rail-500">
          © {new Date().getFullYear()} Help24 ·{" "}
          <a href="https://help24.co.ke/privacy" className="hover:text-rail-200 hover:underline underline-offset-2">Privacy</a> ·{" "}
          <a href="https://help24.co.ke/terms" className="hover:text-rail-200 hover:underline underline-offset-2">Terms</a>
        </p>
      </aside>

      <main className="flex min-h-screen flex-col px-5 py-8 sm:px-10 lg:min-h-0">
        <div className="flex items-center gap-2.5 lg:hidden">
          <Mark size={30} />
          <span className="text-[14px] font-semibold tracking-tight text-gray-900">{product}</span>
        </div>
        <div className="flex flex-1 items-center justify-center py-10">
          <div className="w-full max-w-[360px]">
            <h1 className="text-[24px] font-bold tracking-tight text-gray-900">{title}</h1>
            {subtitle && <div className="mt-1.5 text-[14px] leading-relaxed text-gray-500">{subtitle}</div>}
            <div className="mt-7">{children}</div>
            {below && <div className="mt-6 text-[12.5px] leading-relaxed text-gray-500">{below}</div>}
          </div>
        </div>
        <p className="text-center text-[12.5px] text-gray-400">{help}</p>
      </main>
    </div>
  );
}
