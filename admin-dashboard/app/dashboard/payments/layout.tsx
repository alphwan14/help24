export default function PaymentsLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Payments</h1>
        <p>M-Pesa transactions and escrow</p>
      </div>
      {children}
    </div>
  );
}
