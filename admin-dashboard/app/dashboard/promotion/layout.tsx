import { SectionNav } from "@/components/SectionTabs";

export default function PromotionLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Promotion</h1>
        <p>Campaigns, review, packages and revenue</p>
      </div>
      <SectionNav section="promotion" />
      {children}
    </div>
  );
}
