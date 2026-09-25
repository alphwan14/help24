import { createServiceClient } from "@/lib/supabase-server";

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

  const [postRes, userRes] = await Promise.all([
    db.from("posts").select("location").not("location", "is", null),
    db.from("users").select("location").not("location", "is", null),
  ]);

  const allLocations = [
    ...(postRes.data ?? []).map((r: { location: string | null }) => r.location),
    ...(userRes.data ?? []).map((r: { location: string | null }) => r.location),
  ];

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
    geoPoints: [...topCities, ...(other ? [other] : [])],
    total,
    postCount: postRes.data?.length ?? 0,
    userCount: userRes.data?.length ?? 0,
  };
}

export default async function GeographyPage() {
  const { geoPoints, total, postCount, userCount } = await getGeoData();

  return (
    <div className="space-y-6">
      {/*
        Three figures, one ink colour.

        These were black, indigo and green — three hues for three counts of the
        same kind of thing. The green one was "Users with location", which
        currently reads 0: an ABSENCE rendered in the colour that means a good
        outcome. Colour here was decoration, and decoration that occasionally
        lies.
      */}
      <div className="grid grid-cols-3 gap-4">
        {[
          { value: total, label: "Location data points" },
          { value: postCount, label: "Posts with location" },
          { value: userCount, label: "Users with location" },
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
