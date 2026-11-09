import OverviewHeader from "./OverviewHeader";

export default function OverviewLayout({ children }: { children: React.ReactNode }) {
  // The heading, the Overview tabs and, on General, the attention queue.
  return (
    <div>
      <OverviewHeader />
      {children}
    </div>
  );
}
