import { SectionNav } from "@/components/SectionTabs";

export default function InsightsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Insights</h1>
        <p>Trends and analytics</p>
      </div>
      <SectionNav section="insights" />
      {children}
    </div>
  );
}
