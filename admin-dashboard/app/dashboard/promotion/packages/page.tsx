import Link from "next/link";
import { redirect } from "next/navigation";
import { getCurrentAdmin, getPromotionPackages, startEarly } from "@/lib/api";
import PackagesClient from "./PackagesClient";

export const dynamic = "force-dynamic";

export default async function PromotionPackagesPage() {
  // Every admin may read packages (canEdit below only gates editing), so the
  // read runs alongside the access check and is used once access is confirmed.
  const packagesRequest = startEarly(getPromotionPackages());

  const admin = await getCurrentAdmin();
  if (!admin) redirect("/dashboard/promotion");

  const packages = await packagesRequest;
  const canEdit = admin.role === "senior_admin" || admin.role === "super_admin";

  return (
    <div className="space-y-4">
      <Link href="/dashboard/promotion" className="text-sm text-blue-600 hover:underline">
        ← All campaigns
      </Link>
      <PackagesClient packages={packages} canEdit={canEdit} />
    </div>
  );
}
