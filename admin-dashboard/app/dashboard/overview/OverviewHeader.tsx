"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import type { AlertsResponse } from "@/lib/alerts";
import { getSupabaseBrowser } from "@/lib/supabase-browser";
import {
  attentionItems,
  dateLine,
  firstNameFrom,
  greetingForHour,
  hourIn,
  viewerTimeZone,
  type AttentionItem,
} from "@/lib/greeting";

const GENERAL = "/dashboard/overview";

/**
 * The Overview heading. On General it opens with a greeting and one line of
 * what needs attention; the other Overview tabs keep the plain heading.
 *
 * Everything personal or time-dependent is resolved in the browser after
 * mount (Overview is cached and shared by every admin). Until then the space
 * holds skeleton bars of the final height, so nothing jumps and no wrong
 * greeting is ever shown.
 */
export default function OverviewHeader() {
  const onGeneral = usePathname() === GENERAL;
  return (
    <div className="page-header">
      {onGeneral && <Greeting />}
      <h1 className={onGeneral ? "sr-only" : undefined}>Overview</h1>
      {!onGeneral && <p>Platform health at a glance</p>}
    </div>
  );
}

type Context = { kind: "loading" } | { kind: "items"; items: AttentionItem[] } | { kind: "clear" } | { kind: "unknown" };

function Greeting() {
  const [clock, setClock] = useState<{ greeting: string; date: string } | null>(null);
  const [name, setName] = useState<string | null | undefined>(undefined); // undefined = still resolving
  const [context, setContext] = useState<Context>({ kind: "loading" });

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

  // What needs attention, from the admin alerts the dashboard already
  // computes. Read once. A 401 right after sign-in means the shell is still
  // connecting, so it is retried briefly. A failed or partial check is NOT
  // "all clear": the line then says nothing it cannot stand behind.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      for (let attempt = 0; attempt < 4 && !cancelled; attempt++) {
        try {
          const res = await fetch("/api/admin/alerts", { cache: "no-store" });
          if (res.status === 401) {
            await new Promise((r) => setTimeout(r, 1500));
            continue;
          }
          if (!res.ok) break;
          const body = (await res.json()) as AlertsResponse;
          if (cancelled) return;
          const items = attentionItems(body.alerts ?? []);
          if (items.length > 0) setContext({ kind: "items", items });
          else setContext({ kind: body.unavailable?.length ? "unknown" : "clear" });
          return;
        } catch {
          break;
        }
      }
      if (!cancelled) setContext({ kind: "unknown" });
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const ready = clock !== null && name !== undefined;

  return (
    <div className="flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between sm:gap-6 min-w-0">
      <div className="min-w-0">
        {ready ? (
          <p className="text-xl sm:text-2xl lg:text-[28px] font-semibold text-gray-900 tracking-tight leading-tight break-words">
            {clock.greeting}
            {name ? `, ${name}` : ""}
          </p>
        ) : (
          <div className="h-7 sm:h-8 w-56 max-w-full rounded-md bg-gray-100 animate-pulse" aria-hidden="true" />
        )}
        <ContextLine context={context} />
      </div>
      {clock && (
        <p className="hidden sm:block shrink-0 text-sm text-gray-400 tabular-nums">{clock.date}</p>
      )}
    </div>
  );
}

function ContextLine({ context }: { context: Context }) {
  const base = "text-sm sm:text-[15px] text-gray-500 mt-1.5 leading-relaxed";
  if (context.kind === "loading") {
    return <div className="h-4 w-72 max-w-full rounded bg-gray-100 animate-pulse mt-2.5" aria-hidden="true" />;
  }
  if (context.kind === "clear") return <p className={base}>All clear. Here&apos;s how the platform is doing today.</p>;
  if (context.kind === "unknown") return <p className={base}>Here&apos;s how the platform is doing today.</p>;
  return (
    <p className={base}>
      {context.items.map((item, i) => (
        <span key={item.href}>
          {i > 0 && <span aria-hidden="true" className="mx-1.5 text-gray-300">·</span>}
          <Link href={item.href} className="font-medium text-gray-700 underline-offset-2 hover:underline hover:text-gray-900">
            {item.text}
          </Link>
        </span>
      ))}
    </p>
  );
}
