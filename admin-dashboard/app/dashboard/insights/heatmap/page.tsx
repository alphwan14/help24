import { createServiceClient } from "@/lib/supabase-server";
import { GeographyChart } from "@/components/charts/GeographyChart";

const KENYA_CITIES = [
  "Nairobi", "Mombasa", "Kisumu", "Nakuru", "Eldoret",
  "Thika", "Malindi", "Nyeri", "Kisii", "Machakos",
];

function extractCity(location: string | null): string {
  if (!location) return "Other";
  const loc = location.toLowerCase();
  for (const city of KENYA_CITIES) {
    if (loc.includes(city.toLowerCase())) return city;
  }
  return "Other";
}

async function getHeatmapData() {
  const db = createServiceClient();

  const [postRes, userRes] = await Promise.all([
    db.from("posts").select("location, type, created_at").not("location", "is", null),
    db.from("users").select("location").not("location", "is", null),
  ]);

  const posts = postRes.data ?? [];
  const users = userRes.data ?? [];

  // City counts by type
  const postCounts: Record<string, number> = {};
  const requestCounts: Record<string, number> = {};
  const offerCounts: Record<string, number> = {};
  const userCounts: Record<string, number> = {};

  for (const p of posts) {
    const city = extractCity(p.location);
    postCounts[city] = (postCounts[city] ?? 0) + 1;
    if (p.type === "request") requestCounts[city] = (requestCounts[city] ?? 0) + 1;
    if (p.type === "offer")   offerCounts[city]   = (offerCounts[city] ?? 0) + 1;
  }

  for (const u of users) {
    const city = extractCity(u.location);
    userCounts[city] = (userCounts[city] ?? 0) + 1;
  }

  const allCities = new Set([
    ...Object.keys(postCounts),
    ...Object.keys(userCounts),
  ]);

  const totalPosts = posts.length;
  const geoPoints = Array.from(allCities)
    .map((city) => ({
      city,
      count: postCounts[city] ?? 0,
      pct: totalPosts > 0 ? Math.round(((postCounts[city] ?? 0) / totalPosts) * 100) : 0,
    }))
    .sort((a, b) => b.count - a.count);

  const topCities = geoPoints.filter((g) => g.city !== "Other");
  const other = geoPoints.find((g) => g.city === "Other");
  const sorted = [...topCities, ...(other ? [other] : [])];

  return { sorted, requestCounts, offerCounts, userCounts, totalPosts };
}

export default async function HeatmapPage() {
  const { sorted, requestCounts, offerCounts, userCounts, totalPosts } = await getHeatmapData();

  return (
    <div className="space-y-6">
      {/* Summary */}
      <div className="grid grid-cols-3 gap-4">
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-gray-900">{totalPosts.toLocaleString("en-KE")}</p>
          <p className="text-xs text-gray-500 mt-1">Posts with location</p>
        </div>
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-indigo-600">{sorted.filter((g) => g.city !== "Other").length}</p>
          <p className="text-xs text-gray-500 mt-1">Cities represented</p>
        </div>
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-emerald-600">
            {sorted[0]?.city ?? "—"}
          </p>
          <p className="text-xs text-gray-500 mt-1">Top city</p>
        </div>
      </div>

      {/* Bar chart */}
      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">Activity by City</h3>
        <p className="text-xs text-gray-400 mb-4">Total posts per location</p>
        {sorted.length > 0 ? (
          <GeographyChart data={sorted} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No location data yet</p>
        )}
      </div>

      {/* Detailed breakdown */}
      {sorted.length > 0 && (
        <div className="card p-5">
          <h3 className="text-sm font-semibold text-gray-700 mb-4">City Breakdown</h3>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-100">
                  <th className="text-left py-2 text-xs text-gray-500 font-semibold">City</th>
                  <th className="text-right py-2 text-xs text-gray-500 font-semibold">Requests</th>
                  <th className="text-right py-2 text-xs text-gray-500 font-semibold">Offers</th>
                  <th className="text-right py-2 text-xs text-gray-500 font-semibold">Users</th>
                  <th className="text-right py-2 text-xs text-gray-500 font-semibold">Share</th>
                </tr>
              </thead>
              <tbody>
                {sorted.map((g) => (
                  <tr key={g.city} className="border-b border-gray-50 hover:bg-gray-50">
                    <td className="py-2 font-medium text-gray-800">{g.city}</td>
                    <td className="py-2 text-right text-blue-600">{(requestCounts[g.city] ?? 0).toLocaleString("en-KE")}</td>
                    <td className="py-2 text-right text-purple-600">{(offerCounts[g.city] ?? 0).toLocaleString("en-KE")}</td>
                    <td className="py-2 text-right text-gray-600">{(userCounts[g.city] ?? 0).toLocaleString("en-KE")}</td>
                    <td className="py-2 text-right font-semibold text-gray-700">{g.pct}%</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </div>
  );
}
