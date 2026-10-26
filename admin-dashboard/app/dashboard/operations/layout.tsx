import SectionTabs from "@/components/SectionTabs";

const BASE = "/dashboard/operations";

export default function OperationsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Operations</h1>
        <p>What is happening on Help24 now, and the switches that change it for everyone</p>
      </div>
      <SectionTabs
        tabs={[
          { label: "Live", href: `${BASE}/live` },
          { label: "App controls", href: `${BASE}/controls` },
        ]}
      />
      {children}
    </div>
  );
}
