# Help24 — Web token synchronisation

**Status:** Done. Generator shipped and drift-verified; both web properties synchronised, built and checked in a browser. See OUTCOME at the end.
**Scope:** `help24_website/` and `admin-dashboard/` presentation only. No layout,
content, component structure or responsive behaviour changes except where the
token swap directly forces one.
**Source of truth:** `mobile-app/lib/theme/tokens.dart`.

---

## 0. What was actually wrong

`help24_website/lib/tokens.ts` opens by calling itself "THE single source of
truth for the website", and three lines later says every value in it "was read
out of the Flutter app". Both sentences were true, and together they were the
defect: **the transcription was a human**. The moment the app re-toned, the
website was confidently serving a palette the product no longer used.

Nothing in either file was wrong. The integration was.

## 1. The generator

`mobile-app/test/design_tokens_export_test.dart` reads the live Dart values and
writes `design-tokens.generated.json` into each consumer's own `lib/`.

**Why a test and not a script.** `tokens.dart` imports
`package:flutter/material.dart`, so `Color` comes from `dart:ui`. `dart run`
cannot compile that — it dies inside the FFI transformer, which is not a
packaging detail to work around, it is the engine not being there. The Flutter
test harness *is* the environment where these values exist.

That turns out to be right for a better reason: **the generator and the drift
detector are the same file.** Edit `tokens.dart`, forget to regenerate, and
`flutter test` fails with the command to run. There is no pipeline to remember
and no CI step to add.

Verified both ways: a hand-edited byte in either copy fails the suite, and
regenerating restores it.

```
cd mobile-app && flutter test test/design_tokens_export_test.dart \
  --dart-define=update_tokens=true
```

**Why committed JSON, not an import.** Two Next apps consume this. Neither gets
a cross-package import, a build step or a Dart dependency. The generated file
lands in each app's own `lib/` and is committed; the test is what guarantees the
two copies and the Dart source agree.

**What is exported:** 29 colour roles × 2 themes, the 5 radius rungs, 9 spacing
steps, 10 type roles (with line-height resolved to px, since Flutter's `height`
is a multiplier and CSS wants the value), and 3 motion durations.

**What is not:** motion *curves*. `Curves.easeOut` has no honest
`cubic-bezier()` equivalent, and guessing one would be inventing a value and
calling it generated.

## 2. Names stay. Values move.

The two systems speak different vocabularies — the app is role-based
(`actionFill`, `contentPrimary`), the website is surface-based (`card`,
`primary`). Adopting the app's names on the web would rewrite ~1,598 Tailwind
colour classes for no user-visible gain.

So `tokens.ts` keeps its key names and gains an explicit **map** from app role
to web token. The names stay a stable internal API; the values stop being
hand-copied. The map is the one thing a human maintains, and it is short enough
to argue about.

## 3. The mapping, measured

Δ is straight RGB distance — a rough "did this actually move" rank, where
anything under ~20 is imperceptible in situ.

### Light

| web token | old | new | Δ | app role |
|---|---|---|---|---|
| `page` / `bg-dark` | `#FBF9F6` | `#FAF9F7` | 1 | `page` |
| `surface` | `#F4F0E9` | `#F4F2EE` | 5 | `surfaceSunken` |
| `card` | `#FFFFFF` | `#FFFFFF` | 0 | `surface` |
| `card-hover` | `#FBF8F3` | `#F7F5F1` | 5 | `surfaceRaised` |
| `border` | `#E6E0D6` | `#E3E0D9` | 4 | `borderHairline` |
| `border-strong` | `#8F897E` | `#928D83` | 7 | `borderStrong` |
| **`primary`** | `#5457E8` | `#96620A` | **232** | `accentText` |
| **`primary-bright`** | `#4338CA` | `#96620A` | **213** | `accentText` |
| **`secondary`** | `#0E7490` | `#96620A` | **192** | `accentText` |
| `money` / `success` | `#047857` | `#0B7A4B` | 14 | `positiveText` |
| `warning` | `#AB4E08` | `#A8541A` | 19 | `cautionText` |
| `error` | `#DC2626` | `#C22B22` | 27 | `criticalText` |
| `text-primary` | `#141317` | `#12161A` | 5 | `contentPrimary` |
| `text-secondary` | `#55525C` | `#585F66` | 17 | `contentSecondary` |
| `text-tertiary` | `#6E6A76` | `#686F77` | 8 | `contentTertiary` |
| `pill-inactive` | `#F1ECE3` | `#F4F2EE` | 13 | `neutralSubtle` |
| `pill-inactive-border` | `#DFD7C9` | `#E3E0D9` | 19 | `borderHairline` |

### Dark

Same map. The only entries that move perceptibly are the three accents (Δ 232 /
215 / 270), `warning` (95), `money` (55), `error` (51) and `text-tertiary` (45,
and it is a *lift* — `#6B7280` was 3.5:1 on the dark card, `#868E96` is 4.95:1).

## 4. The visually significant changes — all three are the point

**`primary`, `primary-bright` and `secondary` all collapse onto the amber
accent.** That is the brand change, not a regression: indigo `#6265F0` and cyan
`#22D3EE` appear in no Help24 asset, and the app retired both. `primary-bright`
existed only because indigo measured 4.37:1 on dark; a theme-resolved accent
removes the reason for it, so the name survives as an alias rather than a
concept.

`secondary` costs almost nothing to collapse — **13 uses in total**.

Everything else in the table is under Δ 30 and will not be noticed.

## 5. The one contrast failure, and the 21 sites it forces

A single `primary` token cannot serve every use. Measured on the new values:

| check | light | dark |
|---|---|---|
| `accentText` as text on page | **4.93:1** | **8.78:1** |
| white on `accentText` as a solid fill | 5.19:1 | **2.16:1 FAIL** |
| `contentOnAction` on `actionFill` | 18.18:1 | 17.18:1 |

This is the same wall the app hit, and it is why the app has `actionFill`
separate from `accentText`. On the website `primary` is doing three jobs at
once — the button fill, the accent text, and the `/10` tint behind a badge:

| usage | count | disposition |
|---|---|---|
| `text-primary`, `border-primary`, `ring-primary` | 106 | → `accentText`. No edit. |
| `bg-primary/10` tint | 28 | → `accentText` at 10%. No edit. |
| decorative solid fills (dots, carets, ping rings) | 10 | → accent. No edit; nothing sits on them. |
| **solid `bg-primary` + `text-white` (buttons)** | **21** | **must become `bg-action` + `text-on-action`** |

So the class edits this sprint requires are **21 button sites**, not a rename
sweep — and they are required to avoid shipping white-on-amber at 2.16:1 in
dark mode. New tokens `action` / `on-action` (and `accent` / `accent-subtle` /
`on-accent`) are added to carry the roles the web vocabulary never had a name
for.

## 6. Palettes being deleted

`urgency-urgent/soon/flexible` and `type-request/offer/job` are the
`STATUS_COLOR_CONFLICT` block — six values that existed *only* to faithfully
reproduce the duplicate palettes the app was carrying. The app deleted them;
reproducing a conflict that no longer exists is not fidelity.

They are not referenced as Tailwind classes anywhere. They reach the UI through
`URGENCY` / `POST_TYPES` helpers in two files:

- `components/ds/Badge.tsx` — repointed to semantic tones, mirroring the app's
  `AppChip` (urgent → critical, soon → caution, flexible → positive).
- `components/gallery/Gallery.tsx` — the section that *displays* the conflict is
  deleted along with it.

The app also stopped colour-coding post TYPE at all: it renders
`REQUEST · Plumbing` typographically, in tertiary, with an icon. The website
follows.

## 7. Typography

The website is on **Poppins**; the app moved to **Inter** and bundles it. Poppins
is a geometric display face and Inter is a neo-grotesque UI face — at body sizes
on a dense marketplace listing they are not interchangeable, and "one product"
is the whole argument for this work.

`next/font/google` already downloads at build time and self-hosts, so there is
no runtime request to Google and nothing to change about the hosting approach —
only the face.

The admin dashboard is already on Inter.

## 8. The admin dashboard is a different problem

It has no token file at all: a Tailwind `brand` ramp of indigo (`#4f46e5`), 22
distinct raw hexes across 52 occurrences, no dark mode, no shared vocabulary.
86 files, ~8,800 lines.

It consumes the same generated JSON, but it needs a token layer built rather
than re-pointed.

---

## Order of work

1. ~~Generator + drift test~~ **done, verified**
2. `tokens.ts` — read generated values through an explicit map; add
   `action`/`on-action`/`accent`; delete the retired palettes
3. The 21 button sites
4. `Badge.tsx`, `Gallery.tsx`
5. Poppins → Inter
6. Admin dashboard token layer
7. Verify both properties in a browser, light and dark

---

# OUTCOME

All seven steps done. `flutter test` 1,134 passing · website 75 passing ·
both Next apps typecheck and build clean · both verified in a browser.

## What the implementation changed about the plan

**The `brand` ramp was wrong the first time, and the screenshot said so.**
It was built with amber at the light end and ink at the dark end — which is not
a ramp, it is two unrelated colours joined in the middle. The login page renders
`text-brand-200` as its subtitle, and it came out **tan**: supporting text
reading as a warning. Rebuilt as a single ink axis, with amber reserved to the
semantic names where a call site has to ask for it deliberately.

**The website is a separate git repository.** `help24_website/` has its own
remote and the parent repo gitignores it; `admin-dashboard/` does not. So a
clean checkout of the mobile repo has one consumer and not the other, and the
first version of the drift test would have failed for a reason unrelated to
tokens. A consumer that is not checked out is skipped; one that is present is
verified strictly.

**The corollary is load-bearing: a token change is not fully shipped until BOTH
repositories are committed.**

## The admin dashboard turned out to be an accessibility fix

It had no token layer, so the plan was to build one. Measuring first found
something else: **`text-gray-400` is used 114 times**, and Tailwind's
`gray-400` is `#9ca3af` — **2.6:1 on white**. The dashboard has been shipping
114 pieces of text below the AA floor, with another 121 at `gray-500` (4.8:1)
only just clearing it.

Overriding Tailwind's `gray` with a warm ramp anchored on the app's
`contentTertiary` / `contentSecondary` lifts those to **5.09:1 and 6.47:1**
while keeping their relative order, so every hierarchy those call sites express
still reads — and it costs **zero class edits** across 497 uses.

`gray-150` was also in use, which is not a Tailwind step at all and silently
resolved to nothing. It is defined now.

Three palettes are overridden rather than renamed — `gray` (497 uses), `brand`
(25) and `indigo` (33, all informational, repointed to the app's `info` role so
they stay blue). Between them that is ~555 of the dashboard's 832 colour
classes re-toned without touching a component.

**`gray-400` is not Tailwind's `#9ca3af` in this project.** That is the single
most surprising line in `admin-dashboard/tailwind.config.ts` and it is
documented at the top of it.

## Kept deliberately

- **The website's type SIZES.** `AppTypeScale` tops out at 28px because it is
  designed for a phone; a 1440px marketing page is a different problem. The
  website shares the typeface, the weights and the restraint — not the ramp.
- **The admin is light-only.** It never had a dark theme, and adding one is a
  feature rather than a synchronisation. The generated file carries both
  palettes, so it is a `tokensCss()` change later, not a re-audit.
- **`RADIUS`'s eight names**, now resolving onto five values with two
  deliberate pairs of duplicates. Collapsing the names means editing call sites
  to no visible end.

## Still open

- **The sent chat bubble in the app** is filled with `AppTheme.primaryAccent`
  (`#96620A`) — an accent-TEXT value used as a FILL. Carried over from the app
  sprint; wants a decision about what a sent bubble should BE.
- **`components/gallery/Gallery.tsx`** lost its "two definitions of red, amber
  and green" section along with the conflict it documented. The gallery is now
  slightly shorter than its navigation implies; worth a read-through when
  someone next opens it.
- **Deploying** — the admin dashboard has no git auto-deploy (`vercel --prod`
  ships the working tree), so prod and main can disagree if one is pushed
  without the other.

---

# ADDENDUM — WHAT THE FIRST PASS MISSED, AND THE ADMIN DARK THEME

Reported from the running dashboard: *"still renders the old purple theme."*
Correct, and the cause was mine.

## The miss

The first pass overrode Tailwind **palettes**. It never touched:

- **raw hex values inside components** — `#4f46e5` ×9, `#a78bfa` ×3, `#7c3aed`
  ×2, all in five chart files. Overriding the `indigo` palette does nothing to
  a hard-coded `#4f46e5`.
- **`purple-*` classes** — 14 of them, and `purple` was simply not in the list
  of families I measured.
- **`blue` / `red` / `green` / `amber` / `emerald`** — ~240 more classes still
  on Tailwind defaults.

Everything now resolves to a Help24 token; the compiled CSS contains none of
`#9ca3af`, `#6b7280`, `#4f46e5`, `#a78bfa`, `#7c3aed`, `#d1d5db` or `#f8fafc`.

## The charts were miscoloured by the method's own rules

Both `CategoryChart` and `GeographyChart` are **single-series** bar charts that
painted every bar a different hue and cycled the list with
`i % COLORS.length`. Two things wrong with that:

- colouring nominal bars by their value spends the identity channel
  re-encoding what bar length already shows;
- cycling means a city changes colour when the row count changes, so the same
  place is violet in one view and lilac in the next.

Categories and cities are nominal and there is one series, so there is now one
hue and the title says what it is. `GeographyChart`'s six-step violet ramp is
gone entirely.

Series colour comes from a **validated** categorical palette, not from the
brand: identity is an encoding channel whose job is letting a reader tell two
things apart, including a reader with deuteranopia. Help24's palette is ink,
amber and four status roles — a brand, not a categorical scale — and spending
status hues on series identity would make "critical" and "series 4" the same
red. Measured on the card surface:

| check | result |
|---|---|
| lightness band | PASS |
| chroma floor | PASS |
| CVD separation | PASS — ΔE 24.7 protan (target ≥ 8) |
| normal-vision floor | PASS — ΔE 33.6 (floor 15) |
| contrast vs surface | PASS — both ≥ 3:1 |

Status colour stays reserved: `PaymentStatusChart` reads the app's own
positive/caution/critical/info roles, so a paid transaction is the same green
on the dashboard, the website and the phone.

## Light/dark, light default

Every colour is a CSS custom property and every Tailwind name resolves to
`rgb(var(--x-rgb) / <alpha-value>)`. One class names one ROLE; the theme
decides the value. Light sits on bare `:root`; dark arrives via
`prefers-color-scheme` or `data-theme="dark"`, stamped synchronously by a
~300-byte `ThemeScript` so there is no light flash on navigation. Three states
— Auto / Light / Dark — because a two-state switch cannot say "follow my
machine".

**A ramp step is a role, not a lightness.** `gray-400` is muted text in both
themes — `#686F77` on paper, `#868E96` on ink. That is what let 497 existing
class names survive the addition of a dark theme untouched.

### The three things that broke, and why

**The sidebar.** It is permanently dark — dark chrome beside light content —
and it spells its colours with the same `gray-*` names the content area uses
while meaning the OPPOSITE by them. Flip the ramp and the content resolves
correctly while the rail inverts into a white slab. It has its own `rail`
family now, pinned to the app's dark palette in both themes.

**The rail runs light→dark, unlike every other ramp here.** Its author wrote
`text-gray-700` to mean DIM on dark and `hover:text-gray-500` to mean brighter.
Re-pointing those at a role ramp inverted them — the debug footer went from
barely-there to prominent and its hover ran backwards. So that one ramp is a
literal lightness scale and the existing classes keep their meaning.

**Hard-coded white.** `bg-white` ×20, `text-white` ×22, `border-white` ×7
cannot follow a theme. Cards became `bg-surface`; `text-white` on the ACTION
fill became `text-on-action` (ink inverts, so white would vanish); `text-white`
on a solid status fill stayed, because those fills are identical in both
themes. Three status *buttons* moved from solid+white to the subtle+text
pattern — `bg-green-600` is the positive TEXT value, which in dark is `#3DD68C`
and cannot carry white.

The login and accept-invite screens are fixed-dark brand surfaces like the
rail, and were repointed to it — their gradient was `brand-900 → brand-700`,
which now resolves LIGHT in dark mode and would have hidden their white text.

## Not verified by eye

The authenticated dashboard pages. `/dashboard/*` is behind auth (307), so the
checks there are the compiled CSS and the type system, not a screenshot. The
login screen, the token emission for both themes, and the absence of every
retired hex were all verified directly.
