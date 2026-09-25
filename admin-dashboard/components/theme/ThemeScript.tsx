/**
 * The one script allowed to block the first paint.
 *
 * THE PROBLEM IT SOLVES. The theme has three states — follow the system, force
 * light, force dark — and the third piece of information lives in
 * localStorage, which the server cannot read. Applied from a `useEffect`, the
 * server's guess would paint first and the correction would land after
 * hydration: a user who chose dark on a light machine gets a white flash on
 * every navigation. That flash is the most common defect in theme
 * implementations and it cannot be fixed after the fact.
 *
 * So this runs synchronously in <head>, before <body> exists, and stamps
 * `data-theme` on <html>. It is ~300 bytes, is not hydrated, and is the only
 * inline script in the dashboard.
 *
 * WHEN THE PREFERENCE IS "system" IT WRITES NOTHING. The ABSENCE of the
 * attribute is what lets `@media (prefers-color-scheme: dark)` decide, and that
 * media query is already correct in the first stylesheet — so the default path
 * costs one localStorage read and no DOM write.
 *
 * Mirrors the website's implementation deliberately: two properties with two
 * subtly different theme bootstraps is two sets of flash bugs.
 */

export const THEME_STORAGE_KEY = "help24-admin-theme";

export type ThemeChoice = "system" | "light" | "dark";

/**
 * Kept as a string rather than a function reference: it is injected verbatim,
 * so it must not close over anything and must not throw. Private-mode Safari
 * makes `localStorage` itself throw on access, hence the try/catch around a
 * read that looks like it cannot fail.
 */
const SCRIPT = `try{var t=localStorage.getItem("${THEME_STORAGE_KEY}");if(t==="light"||t==="dark"){document.documentElement.setAttribute("data-theme",t)}}catch(e){}`;

export function ThemeScript() {
  return <script dangerouslySetInnerHTML={{ __html: SCRIPT }} />;
}
