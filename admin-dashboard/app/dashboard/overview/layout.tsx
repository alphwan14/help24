import OverviewHeader from "./OverviewHeader";

export default function OverviewLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      {/* General opens with a greeting and what needs attention; the other
          Overview tabs keep the plain heading. See OverviewHeader. */}
      <OverviewHeader />
      {children}
    </div>
  );
}
