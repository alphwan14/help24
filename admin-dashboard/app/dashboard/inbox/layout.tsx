import { SectionNav } from "@/components/SectionTabs";

export default function InboxLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Inbox</h1>
        <p>Mail to support@ and info@help24.co.ke. Members get your answer by email, signed Help24 Support.</p>
      </div>
      <SectionNav section="inbox" />
      {children}
    </div>
  );
}
