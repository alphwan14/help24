import { SectionNav } from "@/components/SectionTabs";

export default function InboxLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Inbox</h1>
        <p>
          Messages from the app, and mail to support@, info@ and security@help24.co.ke. Answers go back the way they came,
          signed Help24 Support, or Help24 Security for security@ mail.
        </p>
      </div>
      <SectionNav section="inbox" />
      {children}
    </div>
  );
}
