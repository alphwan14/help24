"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import type { PromotionPackageItem } from "@/lib/api";
import { updatePackage } from "@/lib/promotion-actions";

/**
 * Package registry editor. Pricing lives ONLY in the DB — editing here changes
 * what future buyers pay; campaigns already sold keep their purchase-time
 * snapshot (backend guarantee).
 */
export default function PackagesClient({
  packages,
  canEdit,
}: {
  packages: PromotionPackageItem[];
  canEdit: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState<{ price: string; days: string; description: string }>({
    price: "",
    days: "",
    description: "",
  });

  function startEdit(pkg: PromotionPackageItem) {
    setEditing(pkg.id);
    setError(null);
    setDraft({
      price: pkg.price_kes?.toString() ?? "",
      days: pkg.duration_days.toString(),
      description: pkg.description,
    });
  }

  function save(pkg: PromotionPackageItem) {
    const price = parseInt(draft.price, 10);
    const days = parseInt(draft.days, 10);
    if (!pkg.is_custom && (!Number.isInteger(price) || price <= 0)) {
      setError("Price must be a positive whole number of KES.");
      return;
    }
    if (!Number.isInteger(days) || days <= 0) {
      setError("Duration must be a positive whole number of days.");
      return;
    }
    startTransition(async () => {
      const result = await updatePackage(pkg.id, {
        ...(pkg.is_custom ? {} : { price_kes: price }),
        duration_days: days,
        description: draft.description,
      });
      if (result.ok) {
        setEditing(null);
        router.refresh();
      } else {
        setError(result.error ?? "Update failed.");
      }
    });
  }

  function toggleActive(pkg: PromotionPackageItem) {
    startTransition(async () => {
      const result = await updatePackage(pkg.id, { active: !pkg.active });
      if (result.ok) router.refresh();
      else setError(result.error ?? "Update failed.");
    });
  }

  return (
    <div className="space-y-4">
      {error && <div className="card p-3 text-sm text-red-700 bg-red-50">{error}</div>}
      <div className="grid gap-4 md:grid-cols-2">
        {packages.map((pkg) => (
          <div key={pkg.id} className={`card p-5 space-y-2 ${pkg.active ? "" : "opacity-60"}`}>
            <div className="flex items-center justify-between">
              <h3 className="font-semibold">{pkg.name}</h3>
              <span
                className={`badge ${pkg.active ? "bg-green-100 text-green-700" : "bg-gray-100 text-gray-500"}`}
              >
                {pkg.active ? "active" : "hidden"}
              </span>
            </div>

            {editing === pkg.id ? (
              <div className="space-y-2">
                {!pkg.is_custom && (
                  <label className="block text-xs text-gray-500">
                    Price (KES)
                    <input
                      className="input mt-1"
                      inputMode="numeric"
                      value={draft.price}
                      onChange={(e) => setDraft({ ...draft, price: e.target.value })}
                    />
                  </label>
                )}
                <label className="block text-xs text-gray-500">
                  Duration (days)
                  <input
                    className="input mt-1"
                    inputMode="numeric"
                    value={draft.days}
                    onChange={(e) => setDraft({ ...draft, days: e.target.value })}
                  />
                </label>
                <label className="block text-xs text-gray-500">
                  Description
                  <input
                    className="input mt-1"
                    value={draft.description}
                    onChange={(e) => setDraft({ ...draft, description: e.target.value })}
                  />
                </label>
                <div className="flex gap-2 pt-1">
                  <button className="btn-primary text-sm" disabled={pending} onClick={() => save(pkg)}>
                    Save
                  </button>
                  <button className="btn-ghost" disabled={pending} onClick={() => setEditing(null)}>
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <>
                <p className="text-sm text-gray-500">{pkg.description}</p>
                <p className="text-sm">
                  {pkg.is_custom ? (
                    <span className="text-gray-500">Custom pricing (admin-managed)</span>
                  ) : (
                    <span className="font-semibold">
                      KES {pkg.price_kes?.toLocaleString("en-KE")}
                    </span>
                  )}{" "}
                  · {pkg.duration_days} days
                </p>
                {canEdit && (
                  <div className="flex gap-2 pt-1">
                    <button className="btn-ghost border border-gray-200" onClick={() => startEdit(pkg)}>
                      Edit
                    </button>
                    <button
                      className="btn-ghost border border-gray-200"
                      disabled={pending}
                      onClick={() => toggleActive(pkg)}
                    >
                      {pkg.active ? "Hide" : "Show"}
                    </button>
                  </div>
                )}
              </>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
