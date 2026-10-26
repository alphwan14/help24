export default function PartnersLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Partners</h1>
        <p>Agents who bring members to Help24: their codes, their members, and who qualifies</p>
      </div>
      {children}
    </div>
  );
}
