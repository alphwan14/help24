"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import { useAlerts } from "@/components/alerts/AlertsProvider";
import { SectionNav } from "@/components/SectionTabs";
import { waited } from "@/lib/alerts";
import {
  attentionItems,
  dateLine,
  firstNameFrom,
  greetingForHour,
  hourIn,
  viewerTimeZone,
} from "@/lib/greeting";

const GENERAL = "/dashboard/overview";

/**
 * The Overview heading and its tabs. On General it opens with a greeting and
 * the queue of work waiting; the other tabs keep the plain heading.
 *
 * Everything personal or time-dependent is resolved in the browser after
 * mount. Until then the space holds skeleton bars of the final height, so
 * nothing jumps and no wrong greeting is ever shown.
 */
export default function OverviewHeader() {
  const onGeneral = usePathname() === GENERAL;
  return (
    <>
      <div className="page-header">
        {onGeneral && <Greeting />}
        <h1 className={onGeneral ? "sr-only" : undefined}>Overview</h1>
        {!onGeneral && <p>Platform health at a glance</p>}
      </div>
      <SectionNav section="overview" />
      {onGeneral && <AttentionQueue />}
    </>
  );
}

function Greeting() {
  const [clock, setClock] = useState<{ greeting: string; date: string } | null>(null);
  const [name, setName] = useState<string | null | undefined>(undefined); // undefined = still resolving

  // Time of day and date, in the viewer's zone; re-read each minute so a page
  // left open across 12:00 or 17:00 does not keep saying the wrong thing.
  useEffect(() => {
    const zone = viewerTimeZone();
    const tick = () => {
      const now = new Date();
      setClock({ greeting: greetingForHour(hourIn(zone, now)), date: dateLine(zone, now) });
    };
    tick();
    const id = window.setInterval(tick, 60_000);
    return () => window.clearInterval(id);
  }, []);

  // Who is looking: the admin profile's name, else the session email.
  useEffect(() => {
    let cancelled = false;
    const giveUp = window.setTimeout(() => !cancelled && setName((n) => (n === undefined ? null : n)), 2500);
    (async () => {
      let profileName: string | null = null;
      let email: string | null = null;
      try {
        const r = await fetch("/api/admin/identity", { cache: "no-store" });
        const ident = (await r.json()) as { name?: string; email?: string };
        profileName = ident.name ?? null;
        email = ident.email ?? null;
      } catch {
        /* fall back to the session below */
      }
      if (!email) {
        try {
          const { data } = await getSupabaseBrowser().auth.getSession(); // local, no network
          email = data.session?.user.email ?? null;
        } catch {
          /* no name, then */
        }
      }
      if (!cancelled) setName(firstNameFrom(profileName, email));
    })();
    return () => {
      cancelled = true;
      window.clearTimeout(giveUp);
    };
  }, []);

  const ready = clock !== null && name !== undefined;

  return (
    <div className="min-w-0">
      {ready ? (
        // A div, not a <p>: `.page-header p` (globals.css) out-ranks utility
        // classes, which is why the greeting used to render small and grey.
        <div className="text-[22px] lg:text-[26px] font-semibold text-gray-900 tracking-tight leading-tight break-words">
          {clock.greeting}
          {name ? `, ${name}` : ""}
        </div>
      ) : (
        <div className="h-7 w-56 max-w-full rounded-md bg-gray-100 animate-pulse" aria-hidden="true" />
      )}
      {clock ? (
        <div className="text-[13px] text-gray-500 mt-1">{clock.date}</div>
      ) : (
        <div className="h-4 w-32 rounded bg-gray-100 animate-pulse mt-1.5" aria-hidden="true" />
      )}
    </div>
  );
}

/**
 * The work waiting, from the admin alerts the shell already polls (no second
 * fetch). One row per kind of work, each linking to where it is done. A
 * failed or partial check is NOT shown as "all clear": that row then says the
 * checks could not all run.
 */
function AttentionQueue() {
  const alerts = useAlerts();
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const t = window.setInterval(() => setNow(Date.now()), 30_000);
    return () => window.clearInterval(t);
  }, []);

  const data = alerts?.data;
  const loading = !data && !alerts?.error;
  const items = data ? attentionItems(data.alerts ?? [], 8) : [];
  const partial = !!alerts?.error || (data?.unavailable?.length ?? 0) > 0;
  const checked = alerts?.fetchedAt ? waited(new Date(alerts.fetchedAt).toISOString(), now) : null;

  return (
    <section aria-labelledby="attention-heading" className="mb-6 lg:mb-8">
      <div className="flex items-baseline justify-between mb-2.5">
        <h2 id="attention-heading" className="text-[12px] font-semibold text-gray-500">
          Needs attention
        </h2>
        {checked && <span className="text-[11.5px] text-gray-400">Checked {checked} ago</span>}
      </div>

      <div className="bg-surface rounded-xl border border-gray-200 overflow-hidden">
        {loading ? (
          <div className="divide-y divide-gray-100" aria-hidden="true">
            {[0, 1].map((i) => (
              <div key={i} className="h-12 px-4 flex items-center">
                <div className="h-3.5 w-48 rounded bg-gray-100 animate-pulse" />
              </div>
            ))}
          </div>
        ) : items.length > 0 ? (
          <ul className="divide-y divide-gray-100">
            {items.map((item) => (
              <li key={item.href}>
                <Link
                  href={item.href}
                  className="flex items-center gap-3 px-4 h-12 hover:bg-gray-50 transition-colors"
                >
                  <span className="w-1.5 h-1.5 rounded-full bg-caution-500 shrink-0" />
                  <span className="flex-1 text-[14px] text-gray-800 truncate">{item.text}</span>
                  <Chevron className="w-4 h-4 text-gray-300 shrink-0" />
                </Link>
              </li>
            ))}
            {partial && <PartialRow />}
          </ul>
        ) : partial ? (
          <PartialRow />
        ) : (
          <div className="flex items-center gap-3 px-4 h-12">
            <CheckIcon className="w-4 h-4 text-positive-600 shrink-0" />
            <span className="text-[14px] text-gray-700">Nothing waiting on you</span>
          </div>
        )}
      </div>
    </section>
  );
}

function PartialRow() {
  return (
    <div className="flex items-center gap-3 px-4 h-12 text-[13px] text-gray-500">
      <span className="w-1.5 h-1.5 rounded-full bg-gray-300 shrink-0" />
      Some checks could not run. Open the bell for details.
    </div>
  );
}

function Chevron({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5" />
    </svg>
  );
}

function CheckIcon({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2} aria-hidden>
      <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
    </svg>
  );
}
