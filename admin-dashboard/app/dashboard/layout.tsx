import AdminShell from "@/components/AdminShell";

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  // AdminShell (client) owns the single arbitration-restore + readiness gate and
  // renders the sidebar + main layout once arbitration access is confirmed.
  return <AdminShell>{children}</AdminShell>;
}
