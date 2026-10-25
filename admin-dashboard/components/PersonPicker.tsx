"use client";

import { useEffect, useRef, useState } from "react";
import type { LinkCandidate } from "@/lib/api";
import { searchPeople } from "@/lib/admin-actions";

/**
 * Choose the Help24 person a dashboard login — or an invitation — is for.
 *
 * The person is CHOSEN, never inferred: an email that happens to match is
 * evidence, not proof, and linking the wrong pair hands one person another's
 * identity. So this only ever searches and shows; the super admin picks.
 * People who already have a dashboard login cannot be picked — the database
 * allows one per person, and the backend would refuse it anyway.
 */
export default function PersonPicker({
  selected,
  onSelect,
  placeholder = "Search Help24 accounts by name, email or phone",
}: {
  selected: LinkCandidate | null;
  onSelect: (person: LinkCandidate | null) => void;
  placeholder?: string;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<LinkCandidate[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [searching, setSearching] = useState(false);
  const latest = useRef(0);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2) {
      setResults([]);
      setError(null);
      return;
    }
    const ticket = ++latest.current;
    const timer = window.setTimeout(async () => {
      setSearching(true);
      const res = await searchPeople(q);
      if (ticket !== latest.current) return; // a newer query superseded this one
      setSearching(false);
      if (!res.ok) {
        setError(res.error ?? "Search failed.");
        setResults([]);
      } else {
        setError(null);
        setResults(res.data ?? []);
      }
    }, 250);
    return () => window.clearTimeout(timer);
  }, [query]);

  if (selected) {
    return (
      <div className="flex items-center justify-between gap-3 rounded-lg border border-gray-200 bg-gray-50 px-3 py-2">
        <PersonLine person={selected} />
        <button type="button" onClick={() => onSelect(null)} className="text-xs font-semibold text-gray-500 hover:text-gray-800">
          Change
        </button>
      </div>
    );
  }

  return (
    <div className="space-y-2">
      <input
        type="search"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder={placeholder}
        className="input w-full"
        aria-label="Search Help24 accounts"
        autoComplete="off"
      />
      {searching && <p className="text-xs text-gray-400">Searching…</p>}
      {error && <p className="text-xs text-red-600">{error}</p>}
      {!searching && !error && query.trim().length >= 2 && results.length === 0 && (
        <p className="text-xs text-gray-500">
          No Help24 account matches. The person must sign into the Help24 app once before they can be chosen.
        </p>
      )}
      {results.length > 0 && (
        <ul className="divide-y divide-gray-100 rounded-lg border border-gray-200 max-h-64 overflow-y-auto">
          {results.map((p) => (
            <li key={p.id}>
              <button
                type="button"
                disabled={p.has_dashboard_login}
                onClick={() => onSelect(p)}
                className="w-full text-left px-3 py-2 hover:bg-gray-50 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <PersonLine person={p} />
                {p.has_dashboard_login && (
                  <span className="block text-[11px] text-gray-500 mt-0.5">Already has a dashboard login</span>
                )}
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

function PersonLine({ person }: { person: LinkCandidate }) {
  const contact = [person.email, person.phone_number].filter(Boolean).join(" · ");
  return (
    <span className="block min-w-0">
      <span className="block text-sm font-medium text-gray-900 truncate">
        {person.name?.trim() || "Unnamed account"}
        {person.role === "admin" && <span className="badge bg-gray-100 text-gray-700 ml-2 align-middle">admin</span>}
      </span>
      {contact && <span className="block text-xs text-gray-500 truncate">{contact}</span>}
    </span>
  );
}
