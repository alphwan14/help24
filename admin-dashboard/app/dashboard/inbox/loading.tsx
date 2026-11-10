export default function Loading() {
  return (
    <div className="space-y-5" aria-label="Loading" aria-busy="true">
      <div className="flex gap-2">
        {Array.from({ length: 4 }).map((_, i) => (
          <div key={i} className="h-7 w-28 rounded-full bg-gray-100 animate-pulse" />
        ))}
      </div>
      <div className="space-y-2">
        {Array.from({ length: 6 }).map((_, i) => (
          <div key={i} className="h-[76px] rounded-xl bg-surface animate-pulse" />
        ))}
      </div>
    </div>
  );
}
