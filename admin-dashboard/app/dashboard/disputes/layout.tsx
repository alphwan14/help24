export default function DisputesLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Disputes</h1>
        <p>Conflict resolution and escalations</p>
      </div>
      {children}
    </div>
  );
}
