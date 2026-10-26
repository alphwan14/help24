import SectionTabs from "@/components/SectionTabs";

const BASE = "/dashboard/operations";

export default function OperationsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Operations</h1>
        <p>Switches that change what the app does for everyone — every change recorded</p>
      </div>
      <SectionTabs tabs={[{ label: "App controls", href: `${BASE}/controls` }]} />
      {children}
    </div>
  );
}
