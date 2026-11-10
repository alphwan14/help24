import { SectionNav } from "@/components/SectionTabs";

export default function InboxLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Inbox</h1>
        <p>
          Mail to support@, info@ and security@help24.co.ke. Answers go out by email, signed Help24 Support, or Help24
          Security for security@ mail.
        </p>
      </div>
      <SectionNav section="inbox" />
      {children}
    </div>
  );
}
