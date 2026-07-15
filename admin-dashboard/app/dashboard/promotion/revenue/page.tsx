import Link from "next/link";
import { redirect } from "next/navigation";
import { getCurrentAdmin, getPromotionRevenue } from "@/lib/api";

export const dynamic = "force-dynamic";

function kes(n: number) {
  return `KES ${n.toLocaleString("en-KE")}`;
}

export default async function PromotionRevenuePage() {
  const admin = await getCurrentAdmin();
  if (!admin) redirect("/dashboard/promotion");
  if (admin.role !== "senior_admin" && admin.role !== "super_admin") {
    redirect("/dashboard/promotion");
  }

  const revenue = await getPromotionRevenue();
  const byPackage = Object.entries(revenue.by_package).sort(
    (a, b) => b[1].amount_kes - a[1].amount_kes,
  );

  return (
    <div className="space-y-5">
      <Link href="/dashboard/promotion" className="text-sm text-blue-600 hover:underline">
        ← All campaigns
      </Link>

      <div className="grid gap-4 md:grid-cols-3">
        <div className="card p-5">
          <p className="text-xs text-gray-400">Total promotion revenue</p>
          <p className="text-2xl font-bold mt-1">{kes(revenue.total_kes)}</p>
        </div>
        <div className="card p-5">
          <p className="text-xs text-gray-400">Last 30 days</p>
          <p className="text-2xl font-bold mt-1">{kes(revenue.last_30_days_kes)}</p>
        </div>
        <div className="card p-5">
          <p className="text-xs text-gray-400">Paid promotions</p>
          <p className="text-2xl font-bold mt-1">{revenue.payments_count.toLocaleString("en-KE")}</p>
        </div>
      </div>

      <div className="card p-5">
        <h3 className="font-semibold text-sm mb-3">By package</h3>
        {byPackage.length === 0 ? (
          <p className="text-sm text-gray-400">No paid promotions yet.</p>
        ) : (
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left text-xs text-gray-400">
                <th className="pb-2">Package</th>
                <th className="pb-2">Purchases</th>
                <th className="pb-2 text-right">Revenue</th>
              </tr>
            </thead>
            <tbody>
              {byPackage.map(([id, row]) => (
                <tr key={id} className="border-t border-gray-100">
                  <td className="py-2">{row.package_name}</td>
                  <td className="py-2">{row.count}</td>
                  <td className="py-2 text-right font-medium">{kes(row.amount_kes)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
