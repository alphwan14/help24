import { TableSkeleton } from "@/components/moderation/States";

export default function Loading() {
  return (
    <div className="space-y-5" aria-label="Loading">
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="h-[92px] rounded-xl border border-gray-200 bg-surface animate-pulse" />
        ))}
      </div>
      <div className="h-[118px] rounded-xl border border-gray-100 bg-surface animate-pulse" />
      <TableSkeleton rows={8} />
    </div>
  );
}
