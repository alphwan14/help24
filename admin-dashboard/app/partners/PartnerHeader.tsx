import Link from "next/link";
import { KIND_LABELS } from "@/lib/partners/rules";
import type { PartnerAgent } from "@/lib/partners/access";

export default function PartnerHeader({ agent, active }: { agent: PartnerAgent; active: "overview" | "members" }) {
  const tab = (href: string, label: string, on: boolean) => (
    <Link
      href={href}
      aria-current={on ? "page" : undefined}
      className={`px-3 py-2 text-sm font-medium border-b-2 -mb-px ${on ? "border-brand-600 text-gray-900" : "border-transparent text-gray-500 hover:text-gray-800"}`}
    >
      {label}
    </Link>
  );
  return (
    <header className="border-b border-gray-200 bg-surface">
      <div className="mx-auto max-w-4xl px-4 sm:px-6 pt-4 flex items-center justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/favicon.svg" alt="" className="h-8 w-8" />
          <div className="min-w-0">
            <p className="text-[15px] font-semibold text-gray-900 truncate">{agent.display_name}</p>
            <p className="text-[11.5px] text-gray-500">Help24 {KIND_LABELS[agent.kind]} partner</p>
          </div>
        </div>
        <form action="/signout" method="post">
          <button type="submit" className="btn-ghost text-sm">Sign out</button>
        </form>
      </div>
      <nav className="mx-auto max-w-4xl px-4 sm:px-6 mt-2 flex gap-1" aria-label="Partner sections">
        {tab("/", "Overview", active === "overview")}
        {agent.kind !== "research" && tab("/members", "My members", active === "members")}
      </nav>
    </header>
  );
}
