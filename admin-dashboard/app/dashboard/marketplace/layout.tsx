export default function MarketplaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Marketplace</h1>
        <p>Requests, offers, and job activity</p>
      </div>
      {children}
    </div>
  );
}
