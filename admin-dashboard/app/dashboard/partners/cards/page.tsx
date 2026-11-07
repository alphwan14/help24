import Link from "next/link";
import { createServiceClient } from "@/lib/supabase-server";
import { fmtDate, fmtDateTime } from "@/lib/moderation-labels";

export const dynamic = "force-dynamic";

const PATH = "/dashboard/partners/cards";
const WINDOWS = [7, 30, 90] as const;

type CardStats = {
  days: number;
  opens: number;
  opens_qr: number;
  opens_link: number;
  open_app_taps: number;
  download_clicks: number;
  providers_shared: number;
  by_day: Array<{ day: string; opens: number }>;
  by_platform: Record<string, number>;
  top_providers: Array<{
    provider_id: string;
    name: string | null;
    profession: string | null;
    opens: number;
    qr: number;
    open_app: number;
    last_at: string;
  }>;
  first_event_at: string | null;
};

type PageProps = { searchParams: Promise<{ days?: string }> };

/**
 * Is the provider card being handed out? (docs/provider-card.md, Phase A.)
 *
 * Read from Help24's own first-party events (migration 137): help24.co.ke
 * records each open of a card page (/p/<id>), whether it came from the QR
 * code or a shared link, and each "Open in Help24" tap. No cookies and no
 * visitor identifiers, so the numbers are opens, not unique people.
 */
export default async function ProviderCardsPage({ searchParams }: PageProps) {
  const sp = await searchParams;
  const days = WINDOWS.find((d) => String(d) === sp.days) ?? 30;
  const { data, error } = await createServiceClient().rpc("admin_provider_card_stats", { p_days: days });
  const s = (data ?? null) as CardStats | null;

  return (
    <div className="space-y-5" data-testid="provider-card-stats">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <p className="text-[13px] text-gray-500 max-w-2xl">
          Opens of providers&apos; card pages on help24.co.ke, from the QR code or a shared link. Counted first-party — no
          cookies — so these are opens, not unique people.
          {s?.first_event_at ? ` Collecting since ${fmtDate(s.first_event_at)}.` : ""}
        </p>
        <nav aria-label="Time window" className="flex gap-2">
          {WINDOWS.map((d) => (
            <Link
              key={d}
              href={d === 30 ? PATH : `${PATH}?days=${d}`}
              aria-current={d === days ? "page" : undefined}
              className={`px-3 py-1.5 rounded-lg text-xs font-semibold border ${
                d === days ? "bg-gray-900 text-on-action border-gray-900" : "bg-surface text-gray-600 border-gray-200 hover:bg-gray-50"
              }`}
            >
              {d} days
            </Link>
          ))}
        </nav>
      </div>

      {error || !s ? (
        <div className="card p-5 border border-critical-200 bg-critical-50">
          <p className="text-sm font-semibold text-critical-700">Couldn&apos;t load the card numbers</p>
          <p className="text-[13px] text-critical-700/90 mt-1">
            {error?.message?.includes("admin_provider_card_stats")
              ? "The database does not have the card events yet (migration 137)."
              : "Refresh to try again."}
          </p>
        </div>
      ) : (
        <>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Tile label="Card opens" value={s.opens} hint={`${s.opens_qr} from the QR code · ${s.opens_link} from a link`} />
            <Tile label="Providers whose card was opened" value={s.providers_shared} hint="The question Phase A is judged on" />
            <Tile label="“Open in Help24” taps" value={s.open_app_taps} hint="From a card page, by someone with the app" />
            <Tile label="Download taps (whole site)" value={s.download_clicks} hint="Any page, not only cards" />
          </div>

          <section className="card p-4">
            <h3 className="text-[13px] font-semibold text-gray-900">Opens per day</h3>
            {s.by_day.length === 0 ? (
              <p className="text-[13px] text-gray-500 mt-2">No card has been opened in the last {s.days} days.</p>
            ) : (
              <DayBars rows={s.by_day} days={s.days} />
            )}
            {Object.keys(s.by_platform).length > 0 && (
              <p className="text-[12px] text-gray-500 mt-3">
                {Object.entries(s.by_platform)
                  .sort((a, b) => b[1] - a[1])
                  .map(([k, v]) => `${k === "android" ? "Android" : k === "ios" ? "iPhone" : k === "desktop" ? "Computer" : "Unknown"} ${v}`)
                  .join(" · ")}
              </p>
            )}
          </section>

          <section className="card overflow-hidden">
            <div className="px-4 pt-4">
              <h3 className="text-[13px] font-semibold text-gray-900">Providers whose card is being opened</h3>
            </div>
            {s.top_providers.length === 0 ? (
              <p className="text-[13px] text-gray-500 px-4 py-4">Nobody yet.</p>
            ) : (
              <table className="w-full text-[13px] mt-2">
                <thead>
                  <tr className="text-left text-[11.5px] uppercase tracking-wide text-gray-500 border-b border-gray-100">
                    <th className="px-4 py-2 font-semibold">Provider</th>
                    <th className="px-4 py-2 font-semibold text-right">Opens</th>
                    <th className="px-4 py-2 font-semibold text-right">From QR</th>
                    <th className="px-4 py-2 font-semibold text-right">Open in app</th>
                    <th className="px-4 py-2 font-semibold">Last opened</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-gray-100">
                  {s.top_providers.map((p) => (
                    <tr key={p.provider_id}>
                      <td className="px-4 py-2">
                        <Link href={`/dashboard/users/${encodeURIComponent(p.provider_id)}`} className="font-medium text-gray-900 hover:underline">
                          {p.name?.trim() || "Unnamed member"}
                        </Link>
                        {p.profession && <span className="text-gray-500"> · {p.profession}</span>}
                      </td>
                      <td className="px-4 py-2 text-right font-tabular">{p.opens}</td>
                      <td className="px-4 py-2 text-right font-tabular">{p.qr}</td>
                      <td className="px-4 py-2 text-right font-tabular">{p.open_app}</td>
                      <td className="px-4 py-2 text-gray-500">{fmtDateTime(p.last_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </section>
        </>
      )}
    </div>
  );
}

function Tile({ label, value, hint }: { label: string; value: number; hint: string }) {
  return (
    <div className="card px-4 py-3">
      <p className="text-[11.5px] font-semibold uppercase tracking-wide text-gray-500">{label}</p>
      <p className="text-[22px] font-bold text-gray-900 mt-0.5 font-tabular">{value}</p>
      <p className="text-[12px] text-gray-500 mt-0.5">{hint}</p>
    </div>
  );
}

function DayBars({ rows: sparse, days }: { rows: Array<{ day: string; opens: number }>; days: number }) {
  // Every day in the window, so a quiet day shows as a gap instead of
  // disappearing and making the chart look busier than it was.
  const byDay = new Map(sparse.map((r) => [r.day, r.opens]));
  const nairobiToday = new Date(Date.now() + 3 * 3_600_000);
  const rows = Array.from({ length: days }, (_, i) => {
    const d = new Date(nairobiToday.getTime() - (days - 1 - i) * 86_400_000).toISOString().slice(0, 10);
    return { day: d, opens: byDay.get(d) ?? 0 };
  });
  const max = Math.max(1, ...rows.map((r) => r.opens));
  return (
    <div className="mt-3 flex items-end gap-1 h-28" role="img" aria-label="Card opens per day">
      {rows.map((r) => (
        <div key={r.day} className="flex-1 min-w-[6px] flex flex-col items-center justify-end h-full" title={`${r.day}: ${r.opens}`}>
          <div
            className={`w-full rounded-t ${r.opens ? "bg-info-500" : "bg-gray-100"}`}
            style={{ height: r.opens ? `${Math.max(4, (r.opens / max) * 100)}%` : "2px" }}
          />
        </div>
      ))}
    </div>
  );
}
