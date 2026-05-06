import { createServiceClient } from "@/lib/supabase-server";
import { GeographyChart } from "@/components/charts/GeographyChart";

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
      {/* Summary cards */}
      <div className="grid grid-cols-3 gap-4">
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-gray-900">{total.toLocaleString("en-KE")}</p>
          <p className="text-xs text-gray-500 mt-1">Location data points</p>
        </div>
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-indigo-600">{postCount.toLocaleString("en-KE")}</p>
          <p className="text-xs text-gray-500 mt-1">Posts with location</p>
        </div>
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-emerald-600">{userCount.toLocaleString("en-KE")}</p>
          <p className="text-xs text-gray-500 mt-1">Users with location</p>
        </div>
      </div>

      {/* Chart */}
      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">Usage by City</h3>
        <p className="text-xs text-gray-400 mb-4">Combined post + user location data</p>
        {geoPoints.length > 0 ? (
          <GeographyChart data={geoPoints} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No location data yet</p>
        )}
      </div>

      {/* Breakdown table */}
      {geoPoints.length > 0 && (
        <div className="card p-5">
          <h3 className="text-sm font-semibold text-gray-700 mb-4">City Breakdown</h3>
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
      )}
    </div>
  );
}
