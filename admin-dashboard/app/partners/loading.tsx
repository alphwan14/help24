export default function Loading() {
  return (
    <div className="mx-auto max-w-4xl px-4 sm:px-6 py-8 space-y-4" aria-busy="true">
      <div className="card h-40 animate-pulse" />
      <div className="grid gap-3 grid-cols-2 lg:grid-cols-4">
        {[0, 1, 2, 3].map((i) => <div key={i} className="card h-20 animate-pulse" />)}
      </div>
    </div>
  );
}
