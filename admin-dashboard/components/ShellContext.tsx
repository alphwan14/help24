"use client";

import { createContext, useContext } from "react";
import type { AdminRole } from "@/lib/api";

/** What the shell knows that its pieces share: who is signed in, and the search palette. */
export type Shell = {
  role: AdminRole | null;
  openSearch: () => void;
};

export const ShellContext = createContext<Shell>({ role: null, openSearch: () => {} });

export function useShell(): Shell {
  return useContext(ShellContext);
}
