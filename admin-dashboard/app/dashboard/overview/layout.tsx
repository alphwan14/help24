export default function OverviewLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="space-y-1">
      <div className="page-header">
        <h1>Overview</h1>
        <p>Platform health at a glance</p>
      </div>
      {children}
    </div>
  );
}
