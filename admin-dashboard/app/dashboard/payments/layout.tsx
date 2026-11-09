import { SectionNav } from "@/components/SectionTabs";

export default function PaymentsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Payments</h1>
        <p>M-Pesa transactions, escrow and payouts</p>
      </div>
      <SectionNav section="payments" />
      {children}
    </div>
  );
}
