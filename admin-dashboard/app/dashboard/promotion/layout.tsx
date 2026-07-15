export default function PromotionLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Promotion</h1>
        <p>Promote Business — campaigns, moderation, packages & revenue</p>
      </div>
      {children}
    </div>
  );
}
