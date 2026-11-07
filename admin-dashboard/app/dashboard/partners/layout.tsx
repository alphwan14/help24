import SectionTabs from "@/components/SectionTabs";

export default function PartnersLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Partners</h1>
        <p>Who brings members to Help24: agents and their codes, and providers handing out their Help24 card</p>
      </div>
      <SectionTabs
        tabs={[
          { label: "Agents", href: "/dashboard/partners" },
          { label: "Provider cards", href: "/dashboard/partners/cards" },
        ]}
      />
      {children}
    </div>
  );
}
