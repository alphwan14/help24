import { SectionNav } from "@/components/SectionTabs";

export default function DisputesLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Disputes</h1>
        <p>Cases, resolutions and refunds</p>
      </div>
      <SectionNav section="disputes" />
      {children}
    </div>
  );
}
