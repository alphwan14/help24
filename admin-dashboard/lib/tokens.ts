/**
 * Help24 design tokens for the admin dashboard.
 *
 * ── Why this file did not exist before ──────────────────────────────────────
 * The dashboard had no token layer at all: a Tailwind `brand` ramp of indigo
 * (`#4f46e5`, which is Tailwind's own indigo-600), 22 distinct raw hexes across
 * 52 occurrences, and 832 colour classes drawn almost entirely from Tailwind's
 * default palette. Nothing about it said Help24, and nothing connected it to
 * the app or the website.
 *
 * ── Where the values come from ──────────────────────────────────────────────
 * `design-tokens.generated.json`, written out of `mobile-app/lib/theme/
 * tokens.dart` by `mobile-app/test/design_tokens_export_test.dart`. That test
 * also fails on drift, so this file cannot silently fall behind the app. Do not
 * edit the generated file; regenerate it:
 *
 *     cd mobile-app && flutter test test/design_tokens_export_test.dart \
 *       --dart-define=update_tokens=true
 *
 * ── How two themes work here ────────────────────────────────────────────────
 * Every colour is a CSS custom property, and Tailwind's colour names resolve to
 * `rgb(var(--x-rgb) / <alpha-value>)`. So `bg-gray-100` is one class naming one
 * ROLE, and the theme decides its value. Light is the `:root` default; dark
 * arrives by `prefers-color-scheme` or an explicit `data-theme="dark"`.
 *
 * **A ramp STEP is a role, not a lightness.** `gray-400` means "muted text" in
 * both themes — `#686F77` on paper, `#868E96` on ink. That is what lets 497
 * existing class names survive the addition of a dark theme untouched.
 */
import generated from "./design-tokens.generated.json";

export const APP = generated.color.light;
export const APP_DARK = generated.color.dark;

type Palette = typeof generated.color.light;

/* ────────────────────────────────────────────────────────────────────────────
 * RAMP CONSTRUCTION
 * ──────────────────────────────────────────────────────────────────────────── */

function parse(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  // eslint-disable-next-line no-bitwise
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function toHex(rgb: [number, number, number]): string {
  return (
    "#" +
    rgb
      .map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0"))
      .join("")
      .toUpperCase()
  );
}

/**
 * A step between two anchor colours.
 *
 * Used only where the app has no value for a rung. The app defines nine points
 * on the neutral axis, not twelve, and inventing the gaps by hand is how a
 * palette drifts the moment an anchor moves. Deriving them keeps every
 * intermediate tied to a real measured value on each side.
 */
export function mix(a: string, b: string, t: number): string {
  const [x, y] = [parse(a), parse(b)];
  return toHex([0, 1, 2].map((i) => x[i] + (y[i] - x[i]) * t) as [number, number, number]);
}

/**
 * THE NEUTRAL RAMP, REPLACING TAILWIND'S `gray`.
 *
 * ── Why override rather than rename ─────────────────────────────────────────
 * `gray-*` appears 497 times. Renaming it would be 497 edits to produce exactly
 * the pixels the override produces with none.
 *
 * ── The accessibility defect this fixes ─────────────────────────────────────
 * `text-gray-400` is used **114 times**, and Tailwind's `gray-400` is `#9ca3af`
 * — **2.6:1 on white**. The dashboard has been shipping 114 pieces of text
 * below the AA floor. `gray-500` (`#6b7280`) is another 121 uses at 4.8:1, only
 * just clearing it. Anchored on the app's `contentTertiary` /
 * `contentSecondary`, those become **5.09:1 and 6.47:1** with their relative
 * order intact, so the hierarchy each call site expresses still reads.
 *
 * ── Each step is a ROLE ─────────────────────────────────────────────────────
 * 50 ground · 100 sunken · 150 raised · 200 hairline · 300 mid border ·
 * 400 muted text · 500 secondary text · 600–800 stronger text · 900 primary.
 * The dark ramp fills the same roles from the app's dark palette, which is why
 * it reads as an inversion without any call site knowing.
 */
function neutralRamp(p: Palette) {
  return {
    50: p.page,
    100: p.surfaceSunken,
    /** Not a Tailwind step. It was used once as `gray-150`, which silently
        resolved to nothing; defining it turns that into the value it meant. */
    150: p.surfaceRaised,
    200: p.borderHairline,
    300: mix(p.borderHairline, p.borderStrong, 0.45),
    400: p.contentTertiary,
    500: p.contentSecondary,
    600: mix(p.contentSecondary, p.contentPrimary, 0.33),
    700: mix(p.contentSecondary, p.contentPrimary, 0.6),
    800: mix(p.contentSecondary, p.contentPrimary, 0.82),
    900: p.contentPrimary,
    950: mix(p.contentPrimary, p.page, -0.25),
  };
}

/** One semantic role as a Tailwind-shaped ramp: subtle fill, fill, text. */
function semanticRamp(p: Palette, subtle: string, fill: string, text: string) {
  return {
    50: subtle,
    100: subtle,
    200: mix(subtle, fill, 0.35),
    300: mix(subtle, fill, 0.6),
    400: mix(fill, text, 0.25),
    500: fill,
    600: text,
    700: text,
    800: mix(text, p.contentPrimary, 0.35),
    900: mix(text, p.contentPrimary, 0.6),
  };
}

/**
 * THE BRAND RAMP. Was Tailwind indigo; is Help24's INK axis.
 *
 * ── Why ink and not amber ───────────────────────────────────────────────────
 * Help24's primary action is ink, not the accent — amber measures 2.16:1
 * against white and can never carry a label, which is why the app separates
 * `actionFill` from `accentText`. `brand-600` is `.btn-primary`'s fill, so the
 * ramp is anchored where the button is.
 *
 * ── Why it is one hue the whole way ─────────────────────────────────────────
 * The first version ran amber at the light end and ink at the dark end. That is
 * not a ramp, it is two unrelated colours joined in the middle, and it showed
 * immediately: the login page's `text-brand-200` subtitle came out tan, reading
 * as a warning rather than as quiet supporting text.
 */
function brandRamp(p: Palette) {
  return {
    50: p.page,
    100: p.surfaceSunken,
    200: p.borderHairline,
    300: mix(p.borderHairline, p.borderStrong, 0.5),
    400: p.borderStrong,
    500: p.contentSecondary,
    600: p.actionFill, // `.btn-primary`, and the focus ring
    700: p.actionFill,
    800: p.contentPrimary,
    900: mix(p.contentPrimary, p.page, -0.25),
  };
}

/** Every ramp for one theme, keyed by the Tailwind family it replaces. */
function ramps(p: Palette) {
  const neutral = neutralRamp(p);
  const info = semanticRamp(p, p.infoSubtle, p.infoFill, p.infoText);
  const positive = semanticRamp(p, p.positiveSubtle, p.positiveFill, p.positiveText);
  const caution = semanticRamp(p, p.cautionSubtle, p.cautionFill, p.cautionText);
  const critical = semanticRamp(p, p.criticalSubtle, p.criticalFill, p.criticalText);
  const accent = semanticRamp(p, p.accentSubtle, p.accentFill, p.accentText);
  return {
    gray: neutral,
    slate: neutral,
    brand: brandRamp(p),
    /* Informational badges and stat emphasis — still blue, now Help24's. */
    indigo: info,
    info,
    /* Was Tailwind purple: fourteen EMPHASIS uses, none of them status. */
    purple: accent,
    accent,
    blue: info,
    emerald: positive,
    green: positive,
    positive,
    amber: caution,
    yellow: caution,
    orange: caution,
    caution,
    red: critical,
    critical,
  };
}

const LIGHT_RAMPS = ramps(APP);
const DARK_RAMPS = ramps(APP_DARK);

export type RampName = keyof typeof LIGHT_RAMPS;

/** Flat, single-value roles. */
function flats(p: Palette) {
  return {
    page: p.page,
    surface: p.surface,
    "surface-sunken": p.surfaceSunken,
    "surface-raised": p.surfaceRaised,
    border: p.borderHairline,
    "border-strong": p.borderStrong,
    action: p.actionFill,
    "on-action": p.contentOnAction,
    "accent-fill": p.accentFill,
    "accent-text": p.accentText,
    "on-accent": p.contentOnAccent,
    "content-primary": p.contentPrimary,
    "content-secondary": p.contentSecondary,
    "content-tertiary": p.contentTertiary,
  };
}

/**
 * THE RAIL — the sidebar, and the one surface that does NOT follow the theme.
 *
 * The navigation rail is permanently dark: dark chrome beside a light content
 * area, which is how this dashboard has always looked and is a deliberate
 * design rather than an accident of the palette.
 *
 * That makes it the one thing a naive dark theme breaks. The rail spells its
 * colours with the same `gray-*` names the content area uses, and means the
 * OPPOSITE by them — `text-gray-500` is light-on-dark there and dark-on-light
 * everywhere else. Flip the ramp for dark mode and the content resolves
 * correctly while the rail inverts into a white slab.
 *
 * So the rail gets its own family, pinned to the app's DARK palette in both
 * themes. `rail-500` is the same colour whatever the page is doing.
 *
 * ── It runs light→dark, unlike every other ramp here ────────────────────────
 * The content ramps treat a STEP as a ROLE: `gray-900` is primary text in both
 * themes, light or dark. The rail cannot, because the sidebar was written in
 * Tailwind's convention — on a dark surface its author reached for
 * `text-gray-700` to mean DIM and `hover:text-gray-500` to mean brighter.
 *
 * Re-pointing those at a role ramp inverted them: the debug footer went from
 * barely-there to prominent, and its hover went the wrong way. So this one is a
 * literal lightness ramp, 50 lightest to 950 darkest, and the existing classes
 * keep meaning exactly what they meant.
 */
export const RAIL = {
  50: APP_DARK.contentPrimary, //    #F2F4F6  brightest text
  100: mix(APP_DARK.contentPrimary, APP_DARK.contentSecondary, 0.5),
  200: APP_DARK.contentSecondary, // #A8B0B8  readable secondary
  300: mix(APP_DARK.contentSecondary, APP_DARK.contentTertiary, 0.5),
  400: APP_DARK.contentTertiary, //  #868E96  muted
  500: APP_DARK.borderStrong, //     #6E767E  dim, and the hover target
  600: mix(APP_DARK.borderStrong, APP_DARK.borderHairline, 0.45),
  700: mix(APP_DARK.borderStrong, APP_DARK.borderHairline, 0.75),
  800: APP_DARK.borderHairline, //   #2A3035  badge fills, borders
  900: APP_DARK.surface, //          #1B2024  a raised panel in the rail
  950: APP_DARK.page, //             #0E1114  the rail itself
};

/**
 * Semantic colour INSIDE the rail, also pinned.
 *
 * Two role badges and a "Connected" dot live on the sidebar, and they were
 * spelled `indigo-300` / `blue-300` / `emerald-400` — families that now follow
 * the theme. On a surface that does not, that breaks in dark: `indigo-900`
 * resolves light, and a light badge on a light badge is nothing at all.
 */
export const RAIL_SEMANTIC = {
  /** The top role. Amber, because it is the one that should catch an eye. */
  "rail-accent": APP_DARK.accentText,
  "rail-info": APP_DARK.infoText,
  "rail-positive": APP_DARK.positiveText,
};

/* ────────────────────────────────────────────────────────────────────────────
 * CSS CUSTOM PROPERTIES
 * ──────────────────────────────────────────────────────────────────────────── */

/** `#96620A` → `150 98 10`, the form Tailwind's `<alpha-value>` needs. */
function channels(hex: string): string {
  const [r, g, b] = parse(hex);
  return `${r} ${g} ${b}`;
}

/** One name for a token, so Tailwind and the stylesheet cannot disagree. */
export function varName(family: string, step?: string | number): string {
  return step === undefined ? `--${family}-rgb` : `--${family}-${step}-rgb`;
}

/** The Tailwind value for a token: theme-resolved and alpha-capable. */
export function tw(family: string, step?: string | number): string {
  return `rgb(var(${varName(family, step)}) / <alpha-value>)`;
}

/** Tailwind's `colors` object — names only; the values live in CSS. */
export function tailwindColors(): Record<string, string | Record<string, string>> {
  const out: Record<string, string | Record<string, string>> = {};
  for (const family of Object.keys(LIGHT_RAMPS) as RampName[]) {
    out[family] = Object.fromEntries(
      Object.keys(LIGHT_RAMPS[family]).map((step) => [step, tw(family, step)]),
    );
  }
  out.rail = Object.fromEntries(
    Object.keys(RAIL).map((step) => [step, tw("rail", step)]),
  );
  for (const name of Object.keys(RAIL_SEMANTIC)) out[name] = tw(name);
  for (const name of Object.keys(flats(APP))) out[name] = tw(name);
  return out;
}

function block(p: Palette, r: ReturnType<typeof ramps>): string {
  const parts: string[] = [];
  for (const family of Object.keys(r) as RampName[]) {
    for (const [step, hex] of Object.entries(r[family])) {
      parts.push(`${varName(family, step)}:${channels(hex as string)}`);
    }
  }
  for (const [name, hex] of Object.entries(flats(p))) {
    parts.push(`${varName(name)}:${channels(hex)}`);
  }
  return parts.join(";");
}

/**
 * The chart chrome properties, as plain hex rather than `r g b` channels,
 * because Recharts assigns them straight to SVG attributes.
 */
function chartBlock(p: Palette): string {
  return [
    `--chart-surface:${p.surface}`,
    `--chart-grid:${p.borderHairline}`,
    `--chart-axis:${p.borderStrong}`,
    `--chart-label-muted:${p.contentTertiary}`,
    `--chart-label:${p.contentSecondary}`,
    `--chart-ink:${p.contentPrimary}`,
    `--chart-hover:${p.surfaceSunken}`,
    `--chart-positive:${p.positiveFill}`,
    `--chart-positive-strong:${p.positiveText}`,
    `--chart-caution:${p.cautionFill}`,
    `--chart-critical:${p.criticalFill}`,
    `--chart-info:${p.infoFill}`,
    `--chart-neutral:${p.contentTertiary}`,
  ].join(";");
}

/**
 * The stylesheet injected into <head> by app/layout.tsx.
 *
 * LIGHT IS THE DEFAULT and sits on bare `:root`, so a visitor with no stored
 * preference and no system preference gets light. Dark arrives two ways, in
 * this order: the system asks for it and the user has not overridden to light,
 * or `data-theme="dark"` is stamped on <html> by ThemeScript.
 *
 * The rail is emitted ONCE, outside both blocks — see [RAIL].
 */
export function tokensCss(): string {
  const rail = [
    ...Object.entries(RAIL).map(
      ([step, hex]) => `${varName("rail", step)}:${channels(hex)}`,
    ),
    ...Object.entries(RAIL_SEMANTIC).map(
      ([name, hex]) => `${varName(name)}:${channels(hex)}`,
    ),
  ].join(";");

  const light = `${block(APP, LIGHT_RAMPS)};${chartBlock(APP)}`;
  const dark = `${block(APP_DARK, DARK_RAMPS)};${chartBlock(APP_DARK)}`;

  return [
    `:root{color-scheme:light;${light};${rail}}`,
    `@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;${dark}}}`,
    `:root[data-theme="dark"]{color-scheme:dark;${dark}}`,
  ].join("");
}

/* ────────────────────────────────────────────────────────────────────────────
 * CHARTS
 * ──────────────────────────────────────────────────────────────────────────── */

/**
 * Chart colour, split the way chart colour has to be split.
 *
 * ── Brand owns the surface; a validated palette owns identity ───────────────
 * CHROME — the plane, the gridlines, the axis ink — is Help24's, because that
 * is what makes a chart belong in this product. SERIES colour is not a brand
 * decision: it is an encoding channel whose one job is letting a reader tell
 * two things apart, including a reader with deuteranopia. Help24's palette is
 * ink, amber and four status roles — a brand, not a categorical scale — and
 * spending status hues on series identity would make "critical" and "series 4"
 * the same red.
 *
 * So series hues come from a validated categorical palette, in fixed slot
 * order, never cycled. Measured on this dashboard's card surface:
 *
 *     lightness band .......... PASS
 *     chroma floor ............ PASS
 *     CVD separation .......... PASS  ΔE 24.7 protan (target ≥ 8)
 *     normal-vision floor ..... PASS  ΔE 33.6 (floor 15)
 *     contrast vs surface ..... PASS  both ≥ 3:1
 *
 * ── The rule that removed most of the colour here ───────────────────────────
 * Four of the five charts are SINGLE-SERIES, and three were painting every bar
 * a different hue and cycling with `i % COLORS.length`. Colouring nominal bars
 * by their value spends the identity channel re-encoding what bar length
 * already shows, and cycling means a city changes colour when the row count
 * does. One series takes one hue — hence `series[0]` throughout.
 *
 * ── Chrome reads CSS variables ──────────────────────────────────────────────
 * Recharts takes colour as props, not classes, so chrome reads the same custom
 * properties Tailwind does. That is what lets a chart follow the theme.
 */
export const CHART = {
  series: [
    "#2a78d6", // 1 blue    — requests, and every single-series chart
    "#eb6834", // 2 orange  — offers
    "#1baf7a", // 3 aqua
    "#eda100", // 4 yellow
    "#e87ba4", // 5 magenta
    "#008300", // 6 green
    "#4a3aa7", // 7 violet
    "#e34948", // 8 red
  ] as const,

  surface: "var(--chart-surface)",
  grid: "var(--chart-grid)",
  axis: "var(--chart-axis)",
  /** Axis and tick labels. contentTertiary — 5.09:1, was `#9ca3af` at 2.6:1. */
  labelMuted: "var(--chart-label-muted)",
  /** Category names down the Y axis, which people actually read. */
  label: "var(--chart-label)",
  ink: "var(--chart-ink)",
  /** Hover wash behind a bar. */
  hover: "var(--chart-hover)",

  /**
   * STATUS, reserved.
   *
   * Distinct from `series` on purpose: a status colour always means the same
   * thing and is never spent on "series 4". These are the app's own roles, so
   * a paid transaction is the same green on the dashboard, the website and the
   * phone.
   */
  status: {
    positive: "var(--chart-positive)",
    positiveStrong: "var(--chart-positive-strong)",
    caution: "var(--chart-caution)",
    critical: "var(--chart-critical)",
    info: "var(--chart-info)",
    neutral: "var(--chart-neutral)",
  },
} as const;
