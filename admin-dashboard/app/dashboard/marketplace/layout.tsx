import { SectionNav } from "@/components/SectionTabs";

export default function MarketplaceLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Marketplace</h1>
        <p>Requests, offers and jobs</p>
      </div>
      <SectionNav section="marketplace" />
      {children}
    </div>
  );
}
