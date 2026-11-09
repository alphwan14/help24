import { SectionNav } from "@/components/SectionTabs";

export default function TrustSafetyLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Trust and safety</h1>
        <p>Reports, verifications and account decisions. Every action is recorded.</p>
      </div>
      <SectionNav section="trust-safety" />
      {children}
    </div>
  );
}
