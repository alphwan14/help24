/**
 * One figure, and how it moved against the previous equal period.
 *
 * `better` says which direction is good news: more signups is up, more
 * failed payments is down. The pill is green when it moved the good way,
 * red when the bad way, so colour always means "good" or "bad", never just
 * "up" or "down".
 */
export function Stat({
  label,
  value,
  previous,
  current,
  previousText,
  better = "up",
  sub,
  className = "",
}: {
  label: string;
  value: string;
  /** Numbers for the change; omit both for a figure with no comparison. */
  current?: number;
  previous?: number;
  /** How the previous value reads ("KES 4,200", "38%"). */
  previousText?: string;
  better?: "up" | "down" | "neither";
  sub?: string;
  className?: string;
}) {
  const ch = current != null && previous != null ? delta(current, previous) : null;
  const good = ch && ch.dir !== "flat" && better !== "neither" ? (ch.dir === better) : null;

  return (
    <div className={`bg-surface rounded-xl border border-gray-200 px-4 py-3.5 sm:px-5 sm:py-4 min-w-0 ${className}`}>
      <p className="text-[12px] font-medium text-gray-500 truncate">{label}</p>
      <p className="mt-1.5 text-[22px] sm:text-[24px] font-semibold text-gray-900 leading-none tabular-nums tracking-tight truncate">
        {value}
      </p>
      <div className="mt-2 flex items-center gap-1.5 min-h-[18px] min-w-0">
        {ch ? (
          <>
            <span
              className={[
                "inline-flex items-center gap-0.5 rounded-full px-1.5 py-px text-[11px] font-semibold tabular-nums shrink-0",
                good === null ? "bg-gray-100 text-gray-600" : good ? "bg-positive-100 text-positive-700" : "bg-critical-100 text-critical-700",
              ].join(" ")}
            >
              {ch.dir !== "flat" && <Arrow up={ch.dir === "up"} />}
              {ch.text}
            </span>
            {previousText && <span className="text-[11.5px] text-gray-400 truncate">from {previousText}</span>}
          </>
        ) : (
          sub && <span className="text-[11.5px] text-gray-400 truncate">{sub}</span>
        )}
      </div>
    </div>
  );
}

export function delta(current: number, previous: number): { dir: "up" | "down" | "flat"; text: string } | null {
  if (previous === 0 && current === 0) return { dir: "flat", text: "No change" };
  if (previous === 0) return { dir: "up", text: "New" };
  const pct = Math.round(((current - previous) / previous) * 100);
  if (pct === 0) return { dir: "flat", text: "0%" };
  return { dir: pct > 0 ? "up" : "down", text: `${Math.abs(pct)}%` };
}

function Arrow({ up }: { up: boolean }) {
  return (
    <svg viewBox="0 0 12 12" className={["h-2.5 w-2.5", up ? "" : "rotate-180"].join(" ")} aria-hidden>
      <path d="M6 2.5 10 7.5H2z" fill="currentColor" />
    </svg>
  );
}

/** A card with a title and a short line under it, for charts and tables. */
export function Panel({
  title,
  sub,
  right,
  children,
  className = "",
}: {
  title: string;
  sub?: string;
  right?: React.ReactNode;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <section className={`rounded-xl border border-gray-200 bg-surface ${className}`}>
      <div className="flex items-start justify-between gap-3 px-4 sm:px-5 pt-4">
        <div className="min-w-0">
          <h3 className="text-[14px] font-semibold text-gray-900 leading-tight">{title}</h3>
          {sub && <p className="mt-0.5 text-[12px] text-gray-500">{sub}</p>}
        </div>
        {right}
      </div>
      <div className="px-4 sm:px-5 pb-4 pt-3">{children}</div>
    </section>
  );
}
