"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { createContext, useContext, useState, useTransition } from "react";

/**
 * Instant feedback for filters that only change the query string.
 *
 * A route's loading.tsx fires when a SEGMENT changes, never when only
 * `?status=` does — so clicking a status filter left the old list on screen,
 * with nothing to say a click had registered, for the 0.8–3 s the server took
 * (measured on production, 2026-10-26). Here the filter navigates inside a
 * transition: the clicked filter is highlighted at once with a pending dot,
 * and the results dim and announce themselves busy until the new ones land.
 *
 * Still a real link: right-click, middle-click, modifier-click and prefetch
 * behave as they always did. Without a FilterScope it is a plain Link.
 */

type Ctx = { pendingHref: string | null; go: (href: string) => void };
const FilterCtx = createContext<Ctx | null>(null);

export function FilterScope({ children }: { children: React.ReactNode }) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [target, setTarget] = useState<string | null>(null);

  const go = (href: string) => {
    setTarget(href);
    startTransition(() => router.push(href));
  };

  return <FilterCtx.Provider value={{ pendingHref: isPending ? target : null, go }}>{children}</FilterCtx.Provider>;
}

export function FilterLink({
  href,
  active,
  className,
  activeClassName,
  children,
}: {
  href: string;
  active: boolean;
  className: string;
  activeClassName: string;
  children: React.ReactNode;
}) {
  const ctx = useContext(FilterCtx);
  const pending = ctx?.pendingHref === href;
  // While one filter is pending it is the one that reads as chosen.
  const on = pending || (active && !ctx?.pendingHref);

  return (
    <Link
      href={href}
      aria-current={on ? "page" : undefined}
      onClick={(e) => {
        if (!ctx || e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        e.preventDefault();
        ctx.go(href);
      }}
      className={on ? activeClassName : className}
    >
      {children}
      {pending && <span className="ml-1.5 inline-block w-1.5 h-1.5 rounded-full bg-current animate-pulse align-middle" aria-hidden="true" />}
    </Link>
  );
}

/** Dims its contents while a filter in the same scope is loading. */
export function FilterResults({ children }: { children: React.ReactNode }) {
  const busy = useContext(FilterCtx)?.pendingHref != null;
  return (
    <div aria-busy={busy || undefined} className={`transition-opacity duration-150 ${busy ? "opacity-50 pointer-events-none" : ""}`}>
      {children}
    </div>
  );
}
