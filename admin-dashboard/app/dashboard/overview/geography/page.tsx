import { createServiceClient } from "@/lib/supabase-server";

// Rendered per request. `revalidate = 60` read as "at most a minute old", but
// Next rebuilds such a page only when someone asks, and answers that request
// with the old render — on 2026-10-29 the Jobs page left out a job posted 30
// minutes earlier. The dashboard is quiet and each query is one round trip:
// fresh beats fast here (lib/route-freshness.test.mjs).
export const dynamic = "force-dynamic";

const CITIES = ["Nairobi", "Mombasa", "Kisumu", "Nakuru", "Eldoret", "Thika", "Malindi", "Nyeri"];

function extractCity(location: string | null): string {
  if (!location) return "Other";
  const loc = location.toLowerCase();
  for (const city of CITIES) {
    if (loc.includes(city.toLowerCase())) return city;
  }
  return "Other";
}

async function getGeoData() {
  const db = createServiceClient();

  // Listings are the only thing on Help24 that carries a location. This also
  // asked users for one, but users has no location column: the query was
  // refused (400), the error was swallowed, and the page reported a confident
  // "0" users per city. A failed read is now said out loud, never shown as 0.
  const postRes = await db.from("posts").select("location").not("location", "is", null);
  if (postRes.error) return { failed: true as const };

  const allLocations = (postRes.data ?? []).map((r: { location: string | null }) => r.location);

  const counts: Record<string, number> = {};
  for (const loc of allLocations) {
    const city = extractCity(loc);
    counts[city] = (counts[city] ?? 0) + 1;
  }

  const total = Object.values(counts).reduce((s, n) => s + n, 0);

  const geoPoints = Object.entries(counts)
    .sort(([, a], [, b]) => b - a)
    .map(([city, count]) => ({
      city,
      count,
      pct: total > 0 ? Math.round((count / total) * 100) : 0,
    }));

  const topCities = geoPoints.filter((g) => g.city !== "Other");
  const other = geoPoints.find((g) => g.city === "Other");

  return {
    failed: false as const,
    geoPoints: [...topCities, ...(other ? [other] : [])],
    total,
    postCount: postRes.data?.length ?? 0,
  };
}

export default async function GeographyPage() {
  const data = await getGeoData();
  if (data.failed) {
    return <p className="card p-6 text-sm text-gray-500">Location data could not be loaded just now. It refreshes every minute — reload to try again.</p>;
  }
  const { geoPoints, total, postCount } = data;

  return (
    <div className="space-y-6">
      {/*
        Two figures, one ink colour.

        There used to be a third, "Users with location", which always read 0 —
        Help24 records no location for a member, and the query behind it was
        refused outright. A figure that can only ever be zero is not a figure.
      */}
      <div className="grid grid-cols-2 gap-4">
        {[
          { value: total, label: "Location data points" },
          { value: postCount, label: "Posts with location" },
        ].map((s) => (
          <div key={s.label} className="card p-4 text-center">
            <p className="text-2xl font-semibold text-gray-900 tabular-nums">
              {s.value.toLocaleString("en-KE")}
            </p>
            <p className="text-xs text-gray-500 mt-1">{s.label}</p>
          </div>
        ))}
      </div>

      {/*
        ONE VIEW OF THIS DATA, NOT TWO.
    
        This page used to render the same six cities twice, stacked: a
        horizontal bar chart headed "Usage by City", and immediately beneath it
        this list — the same rows, the same order, the same bar lengths. The
        second one simply also carried the count and the percentage.
    
        A reader scrolling past two identical rankings has to stop and work out
        whether they differ, which is work for no answer. The list won because
        it says MORE in less height: Mombasa 34 (64%) is the fact; a bar whose
        length you must compare against an axis is a slower route to it.
      */}
      {geoPoints.length > 0 ? (
        <div className="card p-5">
          <h3 className="text-sm font-semibold text-gray-700 mb-1">Usage by city</h3>
          <p className="text-xs text-gray-400 mb-4">Combined post + user location data</p>
          <div className="space-y-3">
            {geoPoints.map((g) => (
              <div key={g.city} className="flex items-center gap-3">
                <span className="text-sm font-medium text-gray-700 w-24 shrink-0">{g.city}</span>
                <div className="flex-1 bg-gray-100 rounded-full h-2">
                  <div
                    className="bg-indigo-500 h-2 rounded-full transition-all"
                    style={{ width: `${g.pct}%` }}
                  />
                </div>
                <span className="text-sm text-gray-600 w-16 text-right">
                  {g.count.toLocaleString("en-KE")} ({g.pct}%)
                </span>
              </div>
            ))}
          </div>
        </div>
      ) : (
        <div className="card p-5">
          <h3 className="text-sm font-semibold text-gray-700 mb-1">Usage by city</h3>
          <p className="text-gray-400 text-sm py-8 text-center">No location data yet</p>
        </div>
      )}
    </div>
  );
}
