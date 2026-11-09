"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { NAV, SETTINGS_HREF } from "@/lib/nav";
import { searchPeople } from "@/lib/admin-actions";
import type { AdminRole, LinkCandidate } from "@/lib/api";

type Result =
  | { kind: "page"; key: string; label: string; section: string; href: string }
  | { kind: "person"; key: string; label: string; detail: string; href: string };

type PageEntry = Extract<Result, { kind: "page" }> & { haystack: string };

const PAGES: PageEntry[] = [
  ...NAV.flatMap((s) =>
    s.pages.map((p): PageEntry => ({
      kind: "page",
      key: p.href,
      label: p.label,
      section: s.label,
      href: p.href,
      haystack: `${s.label} ${p.label} ${p.keywords ?? ""}`.toLowerCase(),
    })),
  ),
  {
    kind: "page",
    key: SETTINGS_HREF,
    label: "Settings",
    section: "Account",
    href: SETTINGS_HREF,
    haystack: "settings account password appearance theme dark light",
  },
];

/** Pages whose name, section or keywords contain every typed word. */
function matchPages(q: string): PageEntry[] {
  if (!q) return PAGES.filter((p) => NAV.some((s) => s.href === p.href)).slice(0, 10);
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  return PAGES.filter((p) => words.every((w) => p.haystack.includes(w))).slice(0, 8);
}

/**
 * Go anywhere by typing: every page by name, and (for super admins, whom the
 * backend lets search) any Help24 account by name, email or phone.
 *
 * Ctrl+K or Cmd+K opens it anywhere; so does the search button in the rail
 * and on the phone's bottom bar. Arrow keys move, Enter opens, Esc closes.
 */
export default function CommandPalette({
  open,
  onClose,
  role,
}: {
  open: boolean;
  onClose: () => void;
  role: AdminRole | null;
}) {
  const router = useRouter();
  const [query, setQuery] = useState("");
  const [people, setPeople] = useState<LinkCandidate[]>([]);
  const [searching, setSearching] = useState(false);
  const [cursor, setCursor] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);
  const ticket = useRef(0);
  const canSearchPeople = role === "super_admin";

  useEffect(() => {
    if (!open) return;
    setQuery("");
    setPeople([]);
    setCursor(0);
    const t = window.setTimeout(() => inputRef.current?.focus(), 10);
    document.body.style.overflow = "hidden";
    return () => {
      window.clearTimeout(t);
      document.body.style.overflow = "";
    };
  }, [open]);

  useEffect(() => {
    const q = query.trim();
    if (!canSearchPeople || q.length < 2) {
      setPeople([]);
      setSearching(false);
      return;
    }
    const mine = ++ticket.current;
    setSearching(true);
    const timer = window.setTimeout(async () => {
      const res = await searchPeople(q);
      if (mine !== ticket.current) return;
      setSearching(false);
      setPeople(res.ok ? (res.data ?? []).slice(0, 6) : []);
    }, 250);
    return () => window.clearTimeout(timer);
  }, [query, canSearchPeople]);

  const results: Result[] = useMemo(() => {
    const pages = matchPages(query.trim());
    const persons: Result[] = people.map((p) => ({
      kind: "person",
      key: p.id,
      label: p.name || p.email || p.phone_number || "Unnamed account",
      detail: [p.email, p.phone_number].filter(Boolean).join("  "),
      href: `/dashboard/users/${p.id}`,
    }));
    return [...pages, ...persons];
  }, [query, people]);

  useEffect(() => setCursor(0), [query, people.length]);

  if (!open) return null;

  function go(r: Result | undefined) {
    if (!r) return;
    onClose();
    router.push(r.href);
  }

  function onKeyDown(e: React.KeyboardEvent) {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setCursor((c) => Math.min(c + 1, results.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setCursor((c) => Math.max(c - 1, 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      go(results[cursor]);
    } else if (e.key === "Escape") {
      onClose();
    }
  }

  const pageCount = results.filter((r) => r.kind === "page").length;

  return (
    <div className="fixed inset-0 z-[70] flex items-start justify-center sm:pt-[12vh]" role="dialog" aria-modal="true" aria-label="Search">
      <div className="absolute inset-0 bg-black/40" onClick={onClose} aria-hidden />
      <div className="relative w-full h-full sm:h-auto sm:max-w-lg bg-surface sm:rounded-xl sm:border sm:border-gray-200 flex flex-col overflow-hidden">
        <div className="flex items-center gap-3 px-4 border-b border-gray-200">
          <SearchGlyph className="w-4 h-4 text-gray-400 shrink-0" />
          <input
            ref={inputRef}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onKeyDown}
            placeholder={canSearchPeople ? "Search pages and people" : "Search pages"}
            className="flex-1 h-14 bg-transparent text-[15px] text-gray-900 placeholder:text-gray-400 focus:outline-none"
            aria-controls="palette-results"
            aria-activedescendant={results[cursor] ? `palette-${results[cursor].key}` : undefined}
          />
          <button onClick={onClose} className="text-[12px] font-medium text-gray-500 hover:text-gray-800 px-1 py-1">
            Close
          </button>
        </div>

        <ul id="palette-results" role="listbox" className="flex-1 sm:max-h-[60vh] overflow-y-auto py-2">
          {pageCount > 0 && <GroupLabel>Pages</GroupLabel>}
          {results.map((r, i) => (
            <li key={`${r.kind}-${r.key}`} id={`palette-${r.key}`} role="option" aria-selected={i === cursor}>
              {r.kind === "person" && i === pageCount && <GroupLabel>People</GroupLabel>}
              <button
                onMouseEnter={() => setCursor(i)}
                onClick={() => go(r)}
                className={[
                  "w-full flex items-center justify-between gap-3 px-4 py-2.5 text-left",
                  i === cursor ? "bg-gray-100" : "",
                ].join(" ")}
              >
                <span className="min-w-0">
                  <span className="block text-[14px] text-gray-900 truncate">{r.label}</span>
                  {r.kind === "person" && r.detail && (
                    <span className="block text-[12px] text-gray-500 truncate">{r.detail}</span>
                  )}
                </span>
                {r.kind === "page" && <span className="text-[12px] text-gray-400 shrink-0">{r.section}</span>}
              </button>
            </li>
          ))}
          {searching && <li className="px-4 py-2.5 text-[13px] text-gray-400">Searching people</li>}
          {!searching && results.length === 0 && (
            <li className="px-4 py-6 text-center text-[13px] text-gray-500">No matches</li>
          )}
        </ul>

        <div className="hidden sm:flex items-center gap-4 px-4 py-2.5 border-t border-gray-200 text-[11.5px] text-gray-400">
          <span>Enter to open</span>
          <span>Arrows to move</span>
          <span>Esc to close</span>
        </div>
      </div>
    </div>
  );
}

function GroupLabel({ children }: { children: React.ReactNode }) {
  return <p className="px-4 pt-2 pb-1 text-[11px] font-semibold uppercase tracking-wider text-gray-400">{children}</p>;
}

export function SearchGlyph({ className }: { className?: string }) {
  return (
    <svg className={className} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M21 21l-5.197-5.197m0 0A7.5 7.5 0 105.196 5.196a7.5 7.5 0 0010.607 10.607z" />
    </svg>
  );
}
