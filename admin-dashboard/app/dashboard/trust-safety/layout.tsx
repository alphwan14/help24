import SectionTabs from "@/components/SectionTabs";

const BASE = "/dashboard/trust-safety";

export default function TrustSafetyLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Trust &amp; Safety</h1>
        <p>Reports, investigations and account decisions — every action recorded</p>
      </div>
      <SectionTabs
        tabs={[
          { label: "Reports", href: `${BASE}/reports` },
          { label: "Moderation queue", href: `${BASE}/queue` },
          { label: "Suspended", href: `${BASE}/suspended` },
          { label: "Banned", href: `${BASE}/banned` },
          { label: "Restricted", href: `${BASE}/restricted` },
          { label: "Audit log", href: `${BASE}/audit` },
        ]}
      />
      {children}
    </div>
  );
}
