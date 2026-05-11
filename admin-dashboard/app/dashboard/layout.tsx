import Sidebar from "@/components/Sidebar";

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  return (
    /*
     * Desktop (lg+): flex row — sidebar 240px + flex-1 main, full viewport height
     * Mobile (< lg):  block — fixed top bar handled by Sidebar, main has pt-14 offset
     */
    <div className="bg-slate-50 lg:flex lg:h-screen lg:overflow-hidden">
      <Sidebar />
      <main className="flex-1 min-w-0 overflow-y-auto pt-14 lg:pt-0">
        <div className="max-w-[1320px] mx-auto px-4 sm:px-6 lg:px-8 py-5 sm:py-6 lg:py-8">
          {children}
        </div>
      </main>
    </div>
  );
}
