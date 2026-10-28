import Image from "next/image";

/**
 * Miniatures of the product behind each sign-in page — the operations console
 * and the partner overview — drawn from the same tokens as the real pages, so
 * they follow the theme and read as the product rather than as artwork.
 *
 * Nothing here is data. Values are placeholder bars, never numbers: a sign-in
 * page must not show figures that look like Help24's, real or invented.
 */

function Bar({ w, className = "" }: { w: string; className?: string }) {
  return <span className={`block h-2 rounded-full bg-gray-200 ${className}`} style={{ width: w }} />;
}

const NAV = ["Overview", "Operations", "Users", "Marketplace", "Payments", "Disputes", "Trust & Safety", "Partners", "Promotion", "Insights"];
const CHART = [38, 52, 44, 61, 57, 72, 66, 80, 74, 88, 79, 92];

/** The operations console: the dark rail, the Overview tiles, a chart and a queue. */
export function ConsolePreview() {
  return (
    <div
      className="w-full max-w-[680px] overflow-hidden rounded-2xl border border-rail-800 shadow-[0_30px_80px_-20px_rgba(0,0,0,0.6)] flex select-none"
      aria-hidden
    >
      {/* Rail */}
      <div className="w-[27%] shrink-0 bg-rail-950 border-r border-rail-800 px-3 py-4">
        <div className="flex items-center gap-2 px-1.5">
          <Image src="/help24.png" alt="" width={18} height={18} />
          <span className="text-[10px] font-semibold text-rail-50">Help24</span>
        </div>
        <ul className="mt-4 space-y-0.5">
          {NAV.map((label, i) => (
            <li
              key={label}
              className={`flex items-center gap-2 rounded-md px-1.5 py-[5px] text-[9.5px] ${i === 0 ? "bg-white/[0.08] text-rail-50" : "text-rail-400"}`}
            >
              <span className={`h-2 w-2 rounded-[3px] ${i === 0 ? "bg-rail-accent" : "bg-rail-700"}`} />
              {label}
            </li>
          ))}
        </ul>
      </div>

      {/* Content */}
      <div className="flex-1 min-w-0 bg-page p-4 space-y-3">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-[12px] font-bold text-gray-900">Overview</p>
            <Bar w="7rem" className="mt-1.5 !h-1.5" />
          </div>
          <span className="h-5 w-16 rounded-md border border-gray-200 bg-surface" />
        </div>
        <div className="grid grid-cols-4 gap-2">
          {["In the app now", "Jobs in progress", "Held in escrow", "Paying out"].map((label, i) => (
            <div key={label} className="rounded-lg border border-gray-100 bg-surface px-2 py-2">
              <p className="text-[7.5px] font-medium text-gray-500 truncate">{label}</p>
              <span className={`mt-1.5 block h-3 rounded ${i === 2 ? "bg-positive-100" : "bg-gray-200"}`} style={{ width: `${55 - i * 6}%` }} />
            </div>
          ))}
        </div>
        <div className="grid grid-cols-[1.6fr_1fr] gap-2">
          <div className="rounded-lg border border-gray-100 bg-surface p-2.5">
            <p className="text-[8.5px] font-semibold text-gray-700">Requests by week</p>
            <div className="mt-2 flex h-20 items-end gap-1">
              {CHART.map((h, i) => (
                <span key={i} className={`flex-1 rounded-t ${i === CHART.length - 1 ? "bg-brand-600" : "bg-brand-600/35"}`} style={{ height: `${h}%` }} />
              ))}
            </div>
          </div>
          <div className="rounded-lg border border-gray-100 bg-surface p-2.5">
            <p className="text-[8.5px] font-semibold text-gray-700">Needs attention</p>
            <ul className="mt-2 space-y-2">
              {[
                ["bg-critical-100", "68%"],
                ["bg-caution-100", "54%"],
                ["bg-info-100", "74%"],
                ["bg-positive-100", "48%"],
              ].map(([pill, w], i) => (
                <li key={i} className="flex items-center justify-between gap-2">
                  <Bar w={w} />
                  <span className={`h-2.5 w-6 shrink-0 rounded-full ${pill}`} />
                </li>
              ))}
            </ul>
          </div>
        </div>
        <div className="rounded-lg border border-gray-100 bg-surface p-2.5 space-y-2">
          {["82%", "64%", "71%"].map((w, i) => (
            <div key={i} className="flex items-center gap-2">
              <span className="h-4 w-4 shrink-0 rounded-full bg-gray-200" />
              <Bar w={w} />
              <span className="ml-auto h-2.5 w-10 shrink-0 rounded-full bg-gray-100" />
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

/** A fixed QR-like pattern: the shape of the agent's code card, not a scannable code. */
function QrPattern() {
  const n = 17;
  const cells: boolean[] = [];
  let x = 0x2f6b;
  for (let i = 0; i < n * n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    cells.push(((x >> 16) & 1) === 1);
  }
  const finder = (r: number, c: number) =>
    [[0, 0], [0, n - 7], [n - 7, 0]].some(([fr, fc]) => r >= fr && r < fr + 7 && c >= fc && c < fc + 7);
  const finderOn = (r: number, c: number) => {
    for (const [fr, fc] of [[0, 0], [0, n - 7], [n - 7, 0]]) {
      if (r >= fr && r < fr + 7 && c >= fc && c < fc + 7) {
        const dr = r - fr, dc = c - fc;
        return dr === 0 || dr === 6 || dc === 0 || dc === 6 || (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4);
      }
    }
    return false;
  };
  return (
    <svg viewBox={`0 0 ${n} ${n}`} className="h-full w-full" shapeRendering="crispEdges">
      {Array.from({ length: n * n }, (_, i) => {
        const r = Math.floor(i / n), c = i % n;
        const on = finder(r, c) ? finderOn(r, c) : cells[i];
        return on ? <rect key={i} x={c} y={r} width={1} height={1} fill="#111418" /> : null;
      })}
    </svg>
  );
}

/** The partner overview: the agent's code card, the four tiles and the weekly bars. */
export function PartnerPreview() {
  return (
    <div
      className="w-full max-w-[600px] overflow-hidden rounded-2xl border border-rail-800 bg-page shadow-[0_30px_80px_-20px_rgba(0,0,0,0.6)] select-none"
      aria-hidden
    >
      <div className="flex items-center justify-between border-b border-gray-200 bg-surface px-4 py-3">
        <div className="flex items-center gap-2">
          <Image src="/help24.png" alt="" width={20} height={20} />
          <div>
            <Bar w="5.5rem" className="!h-2 bg-gray-300" />
            <Bar w="4rem" className="mt-1 !h-1.5" />
          </div>
        </div>
        <span className="h-5 w-12 rounded-md bg-gray-100" />
      </div>
      <div className="flex gap-4 border-b border-gray-200 bg-surface px-4">
        <span className="border-b-2 border-brand-600 py-1.5 text-[9px] font-semibold text-gray-900">Overview</span>
        <span className="py-1.5 text-[9px] text-gray-500">My members</span>
      </div>
      <div className="space-y-3 p-4">
        <div className="flex items-center justify-between gap-4 rounded-xl border border-gray-100 bg-surface p-3.5">
          <div className="min-w-0">
            <p className="text-[8px] font-semibold text-gray-500">Agent code</p>
            <p className="mt-0.5 font-mono text-[17px] font-bold tracking-wider text-gray-900">H24-····</p>
            <div className="mt-2.5 flex gap-1.5">
              {["Copy code", "Copy link", "Share on WhatsApp"].map((l) => (
                <span key={l} className="rounded-md border border-gray-200 px-1.5 py-1 text-[7.5px] text-gray-600">{l}</span>
              ))}
            </div>
          </div>
          <div className="h-[72px] w-[72px] shrink-0 rounded-md bg-white p-1">
            <QrPattern />
          </div>
        </div>
        <div className="grid grid-cols-4 gap-2">
          {["Members credited", "Qualified", "In progress", "Did not qualify"].map((label, i) => (
            <div key={label} className="rounded-lg border border-gray-100 bg-surface px-2 py-2">
              <p className="text-[7.5px] font-medium text-gray-500 truncate">{label}</p>
              <span className={`mt-1.5 block h-3 rounded ${i === 1 ? "bg-positive-100" : "bg-gray-200"}`} style={{ width: `${48 - i * 7}%` }} />
            </div>
          ))}
        </div>
        <div className="rounded-lg border border-gray-100 bg-surface p-2.5">
          <p className="text-[8.5px] font-semibold text-gray-700">Members credited, by week</p>
          <div className="mt-2 flex h-16 items-end gap-1.5">
            {[18, 30, 26, 42, 38, 55, 61, 78].map((h, i, a) => (
              <span key={i} className={`flex-1 rounded-t ${i === a.length - 1 ? "bg-brand-600" : "bg-brand-600/35"}`} style={{ height: `${h}%` }} />
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
