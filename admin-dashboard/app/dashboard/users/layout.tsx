export default function UsersLayout({ children }: { children: React.ReactNode }) {
  return (
    <div>
      <div className="page-header">
        <h1>Users</h1>
        <p>Manage platform users and roles</p>
      </div>
      {children}
    </div>
  );
}
