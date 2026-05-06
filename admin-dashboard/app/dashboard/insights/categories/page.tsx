import { createServiceClient } from "@/lib/supabase-server";
import { CategoryChart } from "@/components/charts/CategoryChart";

async function getCategoryData() {
  const db = createServiceClient();

  const [requestRes, offerRes] = await Promise.all([
    db.from("posts").select("category").eq("type", "request").not("category", "is", null),
    db.from("posts").select("category").eq("type", "offer").not("category", "is", null),
  ]);

  const requestCounts: Record<string, number> = {};
  for (const p of requestRes.data ?? []) {
    if (!p.category) continue;
    requestCounts[p.category] = (requestCounts[p.category] ?? 0) + 1;
  }

  const offerCounts: Record<string, number> = {};
  for (const p of offerRes.data ?? []) {
    if (!p.category) continue;
    offerCounts[p.category] = (offerCounts[p.category] ?? 0) + 1;
  }

  const allCategories = new Set([...Object.keys(requestCounts), ...Object.keys(offerCounts)]);

  const combined = Array.from(allCategories)
    .map((cat) => ({
      category: cat,
      count: (requestCounts[cat] ?? 0) + (offerCounts[cat] ?? 0),
      requests: requestCounts[cat] ?? 0,
      offers: offerCounts[cat] ?? 0,
    }))
    .sort((a, b) => b.count - a.count);

  const topRequests = Object.entries(requestCounts)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 10)
    .map(([category, count]) => ({ category, count }));

  const topOffers = Object.entries(offerCounts)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 10)
    .map(([category, count]) => ({ category, count }));

  return { combined, topRequests, topOffers };
}

export default async function CategoriesPage() {
  const { combined, topRequests, topOffers } = await getCategoryData();

  const totalPosts = combined.reduce((s, c) => s + c.count, 0);
  const topCombined = combined.slice(0, 15).map((c) => ({ category: c.category, count: c.count }));

  return (
    <div className="space-y-6">
      {/* Summary */}
      <div className="grid grid-cols-3 gap-4">
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-gray-900">{combined.length}</p>
          <p className="text-xs text-gray-500 mt-1">Unique categories</p>
        </div>
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-indigo-600">{topCombined[0]?.category ?? "—"}</p>
          <p className="text-xs text-gray-500 mt-1">Most active category</p>
        </div>
        <div className="card p-4 text-center">
          <p className="text-2xl font-bold text-gray-900">{totalPosts.toLocaleString("en-KE")}</p>
          <p className="text-xs text-gray-500 mt-1">Total categorised posts</p>
        </div>
      </div>

      {/* Combined chart */}
      <div className="card p-5">
        <h3 className="text-sm font-semibold text-gray-700 mb-1">Top Categories (All Posts)</h3>
        <p className="text-xs text-gray-400 mb-4">Requests + offers combined</p>
        {topCombined.length > 0 ? (
          <CategoryChart data={topCombined} />
        ) : (
          <p className="text-gray-400 text-sm py-8 text-center">No category data yet</p>
        )}
      </div>

      {/* Side by side */}
      <div className="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <div className="card p-5">
          <h3 className="text-sm font-semibold text-gray-700 mb-1">Top Request Categories</h3>
          <p className="text-xs text-gray-400 mb-4">What clients need most</p>
          {topRequests.length > 0 ? (
            <CategoryChart data={topRequests} />
          ) : (
            <p className="text-gray-400 text-sm py-8 text-center">No data yet</p>
          )}
        </div>

        <div className="card p-5">
          <h3 className="text-sm font-semibold text-gray-700 mb-1">Top Offer Categories</h3>
          <p className="text-xs text-gray-400 mb-4">What providers supply most</p>
          {topOffers.length > 0 ? (
            <CategoryChart data={topOffers} />
          ) : (
            <p className="text-gray-400 text-sm py-8 text-center">No data yet</p>
          )}
        </div>
      </div>

      {/* Full table */}
      {combined.length > 0 && (
        <div className="card p-5">
          <h3 className="text-sm font-semibold text-gray-700 mb-4">All Categories</h3>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-gray-100">
                  <th className="text-left py-2 text-xs text-gray-500 font-semibold">Category</th>
                  <th className="text-right py-2 text-xs text-gray-500 font-semibold">Requests</th>
                  <th className="text-right py-2 text-xs text-gray-500 font-semibold">Offers</th>
                  <th className="text-right py-2 text-xs text-gray-500 font-semibold">Total</th>
                </tr>
              </thead>
              <tbody>
                {combined.map((c) => (
                  <tr key={c.category} className="border-b border-gray-50 hover:bg-gray-50">
                    <td className="py-2 font-medium text-gray-800">{c.category}</td>
                    <td className="py-2 text-right text-blue-600">{c.requests.toLocaleString("en-KE")}</td>
                    <td className="py-2 text-right text-purple-600">{c.offers.toLocaleString("en-KE")}</td>
                    <td className="py-2 text-right font-semibold text-gray-700">{c.count.toLocaleString("en-KE")}</td>
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
