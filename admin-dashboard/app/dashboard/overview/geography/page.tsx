import { fmtKes } from "@/lib/post-display";
import { geography, pct, placeMatcher } from "@/lib/analytics";
import { periodFor, readApplications, readPlaces, readPosts, readTransactions, settle } from "@/lib/market-data";
import { Panel, Stat } from "@/components/analytics/Stat";
import PlaceMap from "@/components/analytics/PlaceMap";
import { ReadFailed, TabToolbar } from "@/components/analytics/TabToolbar";

// Rendered per request (lib/route-freshness.test.mjs).
export const dynamic = "force-dynamic";

const n = (x: number) => Math.round(x).toLocaleString("en-KE");

/**
 * Where the marketplace is working, and where it is not.
 *
 * Posts carry free-text locations; they are matched to Help24's place
 * registry (migration 088: 479 cities, towns and areas with coordinates) and
 * areas roll up to their town or city. For each place: demand (requests),
 * supply (offers), whether demand got an answer and a hire, and the money.
 * This replaced a single count of posts per city.
 */
export default async function GeographyPage({ searchParams }: { searchParams: Promise<{ period?: string }> }) {
  const period = await periodFor(searchParams);
  const read = await settle(async () => {
    const [posts, apps, tx, places] = await Promise.all([
      readPosts(period, "id, created_at, type, location, status, selected_provider_id"),
      readApplications(period),
      readTransactions(period),
      readPlaces(),
    ]);
    return geography(posts, apps, tx, placeMatcher(places), period);
  });

  return (
    <div>
      <TabToolbar title="Geography" sub="Demand, supply and money by place" period={period} />
      {!read.ok ? <ReadFailed what="places" error={read.error} /> : <GeoView g={read.data} />}
    </div>
  );
}

function GeoView({ g }: { g: ReturnType<typeof geography> }) {
  const top = g.places[0] ?? null;
  const totalPosts = g.located + g.unmatched;
  const active = g.places.filter((p) => p.requests + p.offers > 0);

  if (active.length === 0) {
    return (
      <div className="rounded-xl border border-gray-200 bg-surface p-6 text-center">
        <p className="text-[14px] font-semibold text-gray-900">No located activity in this period</p>
        <p className="mt-1 text-[13px] text-gray-500">
          {g.unmatched > 0 ? `${n(g.unmatched)} posts had a location that did not match a known place.` : "Try a longer period."}
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-5">
      <div className="grid grid-cols-2 gap-2.5 sm:gap-4 lg:grid-cols-4">
        <Stat label="Active places" value={n(active.length)} sub={`In ${n(g.counties.length)} counties`} />
        <Stat label="Busiest place" value={top ? top.name : "None"} sub={top ? `${n(top.requests)} requests, ${n(top.offers)} offers` : undefined} />
        <Stat
          label="Most unanswered"
          value={g.underserved ? g.underserved.name : "None"}
          sub={g.underserved ? `${n(g.underserved.requests - g.underserved.responded)} of ${n(g.underserved.requests)} requests unanswered` : "Every place with demand got answers"}
        />
        <Stat
          label="Fastest growing"
          value={g.growing ? g.growing.name : "None"}
          sub={g.growing ? `${n(g.growing.requests)} requests, from ${n(g.growing.requestsBefore)}` : "No place grew in requests"}
        />
      </div>

      <div className="grid grid-cols-1 gap-5 lg:grid-cols-5">
        <Panel className="lg:col-span-2" title="Map" sub="Each dot is a place with activity">
          <PlaceMap places={g.places} />
        </Panel>

        <Panel className="lg:col-span-3" title="Places" sub="Busiest first. Answered: requests with at least one response">
          <ul className="divide-y divide-gray-100">
            <li className="hidden md:grid grid-cols-[1.4fr_64px_64px_1fr_64px_104px] gap-3 pb-2 text-[11.5px] font-medium text-gray-400">
              <span>Place</span>
              <span className="text-right">Requests</span>
              <span className="text-right">Offers</span>
              <span>Answered</span>
              <span className="text-right">Hired</span>
              <span className="text-right">Earnings</span>
            </li>
            {g.places.slice(0, 15).map((p) => {
              const answered = p.requests > 0 ? p.responded / p.requests : null;
              return (
                <li key={p.id} className="py-2.5 text-[13px]">
                  <div className="grid grid-cols-[1fr_auto] md:grid-cols-[1.4fr_64px_64px_1fr_64px_104px] gap-x-3 gap-y-1 items-center">
                    <span className="min-w-0">
                      <span className="block text-gray-900 font-medium truncate">{p.name}</span>
                      <span className="block text-[11.5px] text-gray-400 truncate">{p.county || "County unknown"}</span>
                    </span>
                    <span className="md:hidden text-right tabular-nums text-gray-500 text-[12.5px]">
                      <span className="font-semibold text-gray-900">{n(p.requests)}</span> req, {n(p.offers)} off
                    </span>
                    <span className="hidden md:block text-right tabular-nums font-semibold text-gray-900">{n(p.requests)}</span>
                    <span className="hidden md:block text-right tabular-nums text-gray-600">{n(p.offers)}</span>
                    <span className="col-span-2 md:col-span-1 flex items-center gap-2">
                      <span className="h-1.5 flex-1 rounded-full bg-gray-100 overflow-hidden">
                        {answered != null && (
                          <span
                            className={["block h-full rounded-full", answered >= 0.5 ? "bg-positive-500" : answered > 0 ? "bg-caution-500" : "bg-critical-500"].join(" ")}
                            style={{ width: `${Math.max(3, answered * 100)}%` }}
                          />
                        )}
                      </span>
                      <span className="w-9 text-right text-[11.5px] text-gray-500 tabular-nums">{answered != null ? pct(answered) : "None"}</span>
                    </span>
                    <span className="hidden md:block text-right tabular-nums text-gray-600">{n(p.hired)}</span>
                    <span className="hidden md:block text-right tabular-nums text-gray-900">{fmtKes(p.fees)}</span>
                  </div>
                  <p className="md:hidden mt-1 text-[11.5px] text-gray-400 tabular-nums">
                    {n(p.hired)} hired, {fmtKes(p.fees)} earned
                  </p>
                </li>
              );
            })}
          </ul>
          {g.places.length > 15 && <p className="pt-2 text-[12px] text-gray-400">And {n(g.places.length - 15)} more places</p>}
        </Panel>
      </div>

      <Panel title="By county" sub="Places rolled up to their county">
        <div className="grid grid-cols-1 gap-x-8 sm:grid-cols-2">
          {g.counties.slice(0, 12).map((c) => {
            const maxReq = Math.max(1, g.counties[0]?.requests ?? 1);
            return (
              <div key={c.county} className="py-2 border-b border-gray-100">
                <div className="flex items-baseline justify-between gap-3 text-[13px]">
                  <span className="text-gray-800 truncate">{c.county}</span>
                  <span className="tabular-nums text-gray-500 text-[12px] shrink-0">
                    <span className="font-semibold text-gray-900">{n(c.requests)}</span> requests, {n(c.offers)} offers
                  </span>
                </div>
                <div className="mt-1.5 h-1.5 rounded-full bg-gray-100 overflow-hidden">
                  <div className="h-full rounded-full bg-info-500" style={{ width: `${c.requests > 0 ? Math.max(2, (c.requests / maxReq) * 100) : 0}%` }} />
                </div>
              </div>
            );
          })}
        </div>
      </Panel>

      <p className="text-[12px] text-gray-400">
        {n(g.located)} of {n(totalPosts)} posts in the period matched a known place ({pct(totalPosts ? g.located / totalPosts : 0)}).
        {g.unmatched > 0 && " The rest had a location Help24's place list does not recognise yet."}
      </p>
    </div>
  );
}
