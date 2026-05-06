export default function InsightsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Insights</h1>
        <p>Deep analytics and intelligence</p>
      </div>
      {children}
    </div>
  );
}
