import Image from "next/image";

/**
 * The frame every sign-in page sits in — admin.help24.co.ke and
 * partners.help24.co.ke alike — so the first screen anyone sees says where
 * they are, who it is for, and where to get help, before it asks for a
 * password.
 *
 * Desktop: a dark brand panel (the sidebar's always-dark `rail` palette, so
 * it reads the same in both themes) beside a light form panel. Phone: the
 * panel folds into a compact header above the form. Deliberately plain —
 * the mark, three sentences, the form — no imagery to load or date.
 */

export type AuthAudience = {
  /** "Help24 Operations", "Help24 Partners". */
  product: string;
  /** One line: what this place is for. */
  headline: string;
  /** One or two sentences under the headline. */
  lede: string;
  /** Three short facts about the place, each a single line. */
  points: string[];
  /** Who to ask when signing in does not work. */
  help: React.ReactNode;
};

function Check() {
  return (
    <svg viewBox="0 0 20 20" fill="currentColor" className="h-4 w-4 shrink-0 text-rail-accent mt-0.5" aria-hidden>
      <path
        fillRule="evenodd"
        d="M16.704 5.29a1 1 0 01.006 1.414l-7.5 7.57a1 1 0 01-1.42.003L3.29 9.79a1 1 0 111.42-1.408l3.79 3.825 6.79-6.853a1 1 0 011.414-.006z"
        clipRule="evenodd"
      />
    </svg>
  );
}

function Mark({ size }: { size: number }) {
  // The mark carries its own squircle, so it sits on either panel with no plate.
  return <Image src="/help24.png" alt="" width={size} height={size} className="shrink-0" priority />;
}

export default function AuthShell({
  audience,
  title,
  subtitle,
  children,
  below,
}: {
  audience: AuthAudience;
  title: string;
  subtitle?: React.ReactNode;
  children: React.ReactNode;
  /** Quiet notes under the form (how access works). */
  below?: React.ReactNode;
}) {
  return (
    <div className="min-h-screen bg-page lg:grid lg:grid-cols-[minmax(0,5fr)_minmax(0,6fr)]">
      {/* ── Brand panel (desktop) ─────────────────────────────────────── */}
      <aside className="hidden lg:flex flex-col justify-between bg-rail-950 px-12 py-10 xl:px-16">
        <div className="flex items-center gap-3">
          <Mark size={36} />
          <span className="text-[15px] font-semibold tracking-tight text-rail-50">{audience.product}</span>
        </div>
        <div className="max-w-md">
          <h2 className="text-[28px] leading-[1.2] font-bold tracking-tight text-rail-50">{audience.headline}</h2>
          <p className="mt-4 text-[15px] leading-relaxed text-rail-200">{audience.lede}</p>
          <ul className="mt-8 space-y-3.5">
            {audience.points.map((p) => (
              <li key={p} className="flex gap-3 text-[14px] leading-snug text-rail-100">
                <Check />
                <span>{p}</span>
              </li>
            ))}
          </ul>
        </div>
        <p className="text-[12px] text-rail-400">
          © {new Date().getFullYear()} Help24 ·{" "}
          <a href="https://help24.co.ke/privacy" className="hover:text-rail-200 underline-offset-2 hover:underline">Privacy</a> ·{" "}
          <a href="https://help24.co.ke/terms" className="hover:text-rail-200 underline-offset-2 hover:underline">Terms</a>
        </p>
      </aside>

      {/* ── Form panel ────────────────────────────────────────────────── */}
      <main className="flex min-h-screen flex-col px-5 py-8 sm:px-10 lg:min-h-0">
        <div className="flex items-center gap-2.5 lg:hidden">
          <Mark size={32} />
          <span className="text-[15px] font-semibold tracking-tight text-gray-900">{audience.product}</span>
        </div>

        <div className="flex flex-1 items-center justify-center py-10">
          <div className="w-full max-w-[380px]">
            <h1 className="text-[26px] font-bold tracking-tight text-gray-900">{title}</h1>
            {subtitle && <div className="mt-2 text-[14.5px] leading-relaxed text-gray-500">{subtitle}</div>}
            <div className="mt-8">{children}</div>
            {below && <div className="mt-8 space-y-1.5 text-[12.5px] leading-relaxed text-gray-500">{below}</div>}
          </div>
        </div>

        <p className="text-center text-[12.5px] text-gray-400">{audience.help}</p>
      </main>
    </div>
  );
}
