import { SectionNav } from "@/components/SectionTabs";

export default function PartnersLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Partners</h1>
        <p>Agents and their codes, and provider cards</p>
      </div>
      <SectionNav section="partners" />
      {children}
    </div>
  );
}
