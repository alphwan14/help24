import { SectionNav } from "@/components/SectionTabs";

export default function OperationsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Operations</h1>
        <p>What is happening now, and the switches that change it for everyone</p>
      </div>
      <SectionNav section="operations" />
      {children}
    </div>
  );
}
