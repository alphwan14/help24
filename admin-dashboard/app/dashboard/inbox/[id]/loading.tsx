export default function Loading() {
  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_280px]" aria-label="Loading" aria-busy="true">
      <div className="space-y-4">
        <div className="h-7 w-2/3 rounded bg-gray-100 animate-pulse" />
        {Array.from({ length: 3 }).map((_, i) => (
          <div key={i} className="h-28 rounded-xl bg-surface animate-pulse" />
        ))}
        <div className="h-40 rounded-xl bg-surface animate-pulse" />
      </div>
      <div className="h-48 rounded-xl bg-surface animate-pulse" />
    </div>
  );
}
