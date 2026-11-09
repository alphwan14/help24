import { SectionNav } from "@/components/SectionTabs";

export default function UsersLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Users</h1>
        <p>Accounts, activity and admin roles</p>
      </div>
      <SectionNav section="users" />
      {children}
    </div>
  );
}
