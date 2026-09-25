# Help24 — Product/UI Audit and Proposed Design Direction

**Status:** Two sprints closed. Audit + direction agreed; Phase 5 steps 1–12 shipped (Addenda B–G), then the whole deferred backlog — all seven items — taken on and closed (Addendum H). Verified on hardware in both themes. Next: website + admin dashboard.
**Date:** 2026-09-24, amended 2026-09-25
**Scope:** `mobile-app/` presentation layer. Backend, API contracts, auth, payments, escrow and state management are out of scope by design.

---

## 0. Method — what this audit is based on

This is not a read of the source. The app was built and run, and every claim below is
either a screenshot, a measurement, or a line of code.

| Evidence | How |
| --- | --- |
| The running product | `flutter build web --release`, served locally, driven in an isolated headless Chrome at **412 × 915 @2x** (a Pixel-class viewport) |
| Real content | Live Supabase data — the actual 2026 Mombasa listings, real avatars, real author names |
| Screen inventory | Flutter's semantics tree, read out of the DOM, giving every node's label, role and measured height |
| Contrast | WCAG 2.1 relative-luminance maths run over the real token values |
| Token sprawl | `grep` counts across all 173 Dart files |

Two limits worth stating plainly:

- The first pass had **no Android device attached**, so it used Flutter's web renderer
  (CanvasKit). A second pass then ran on a real **SM-G986U, signed in, with the backend
  reachable** — see Addendum A for the three findings only the device could show.
- `api.help24.co.ke` was unreachable from the harness, so the ranking engine,
  promotions and the reputation service all fell back. The feed you see below is the
  **chronological fallback path**, and the trust line rendered empty. That is correct
  behaviour, and it is also how the app looks to a user on a bad connection — which
  turned out to be informative in its own right (§3.9).

One temporary edit was made to run on web at all: `LocationService.serviceEnabledStream()`
calls `Geolocator.getServiceStatusStream()`, which throws `UnsupportedError` on web and
took down the whole widget tree. It was stubbed for the duration and **reverted** —
`git status` is back to its pre-audit state.

---

# PHASE 1 — PRODUCT AUDIT

## 1. The product as actually built

**Shell.** `HomeScreen` holds an `IndexedStack` of four tabs behind a five-slot custom
bottom bar. Slot 3 is not a tab — it is a modal-ish `_showPostScreen` boolean that
swaps the body and hides the nav.

```
Discover ──── Jobs ──── [ Post ] ──── Messages ──── Profile
```

**Where everything actually lives.** 30 screens, 26 widget files, ~27,700 lines of
screen code. Navigation is **62 `MaterialPageRoute` pushes and zero named routes** —
there is no route table anywhere in the app.

| Surface | Reached from |
| --- | --- |
| Discover, Jobs, Messages, Profile | bottom nav |
| Post composer | centre button |
| Notifications, Urgent requests | Discover header |
| Post detail, Filter sheet | Discover / Jobs cards |
| Applications, Job lifecycle, Approve/dispute, Mark complete, Payment, Receipt, Review | **only from inside Post detail** |
| My Posts, Saved, Service History, Become a Provider, Payout Destinations, Promote Business, Professional Profile, Payment Number | **only from Profile** |

That last row is the structural finding: **Profile is the app's control panel.** Eight
product surfaces, four preferences, four support links and a sign-out are all stacked
in one scrolling list.

And the row above it is the second one: everything about *a job you are currently doing*
— applicants, lifecycle, completion, payment, dispute — is reachable only by finding
the listing again and opening it. There is no answer to *"what is happening with my
work right now?"*

## 2. What is already good, and must survive

This app has had real design thinking applied to it. Several things below are better
than what a redesign would naively replace them with, and they constrain the work.

**2.1 The icon language is solved.** `lib/theme/app_icons.dart` is 609 lines of
deliberate, semantically-named, single-family (Iconsax Linear) tokens, with the two
Material exceptions bounded and justified, and a documented rule that every token was
*rendered on an SM-G986U* before being accepted — because Iconsax ships codepoints
that silently draw nothing. **149 tokens, 137 Iconsax, 21 Material.** This is better
practice than most shipping apps. I am not going to replace it. (§3.2 is about how
icons are *used*, not which family.)

**2.2 The auth sheet is the best screen in the app.** One brand mark, one line of
positioning, one contextual reason, one primary action, two alternates, one legal line.
No explanation of what email is. This is the target quality bar for everything else —
and it already exists inside this product.

**2.3 The feed state machine.** `FeedPresentation` names four states explicitly —
loading / content / empty / failed — with a documented rule that "No posts found" is
terminal and reachable only from a *completed load for the question currently being
asked*, and that a load failure is never rendered as emptiness. Transitions crossfade
and the list is never cleared to reach a state. Most apps get this wrong.

**2.4 One ownership rule, one CTA rule.** `utils/post_ownership.dart` is the single
source of truth for "is this mine" and "what verb does this listing offer", shared by
Discover, Jobs and detail. It exists because the same job once said "Apply" on one tab
and "Enquire" on another.

**2.5 Feed stability.** A better ranking is *offered*, not applied: it lands when the
reader is back at the top or has left the tab. Sponsored slots obey the same gate. This
is a genuinely sophisticated contract and none of it is visual.

**2.6 Theme is already tri-state.** `ThemePreference{system, light, dark}` with
persistence and a proper `ThemeMode`. The plumbing for §7 of the brief already exists.

**2.7 The copy in auth and guest-profile is already excellent.** *"Find help. Offer
services."* *"Sign in to post a job, apply for work and message people."* — with a
code comment explaining that "Sign in to access all features" is true of every app ever
written. Someone already fought this fight. The copy problem (§3.6) is **localised to
Profile and card chrome**, not app-wide, and the audit must not blanket-condemn it.

## 3. Problems

### 3.1 Typography

The app is **Poppins at every size**, via `GoogleFonts.poppinsTextTheme()`.

Poppins is a *geometric display* face — single-storey `a`, circular `o`, near-uniform
stroke, wide letterfit. It is one of the most-used fonts on Dribbble and in free UI
kits, and that is exactly the association it carries. At 15 px w700 (the feed card
title) it is wide and soft: *"Looking for somone who can step in and operate mtambo
yangu huku Kadzonzo the…"* wraps to two lines and truncates where a text face would
have fitted the sentence. Industry guidance is consistent on this — Inter and its peers
are neo-grotesques *designed for screen UI*, with a taller x-height and open apertures
that hold up at 12–14 px, while Poppins' circular geometry suits headings.

Three further problems, all in `app_theme.dart`:

1. **13 text styles are declared and the app barely uses them.** Call sites constantly
   `.copyWith(fontSize: 15)`, `fontSize: 12.5`, `fontSize: 11.5`. `post_card.dart`
   alone overrides the size on nearly every text node. The scale is advisory, not
   enforced.
2. **No line heights.** Not one `height:` in the entire `TextTheme`. Every block of
   body copy inherits Flutter's default leading, which is why the two-line card titles
   look cramped and the description looks loose — they have *different* effective
   leading by accident.
3. **The scale is arbitrary.** 32/28/24/20/18/16/14/12/10 is a hand-picked ladder, not
   a ratio, and `bodyMedium` (14) is defined as *secondary-coloured* — so any widget
   that reaches for "body text" gets grey text it did not ask for.

**And the font is not bundled.** There is no `fonts:` section in `pubspec.yaml` and no
`.ttf` anywhere in the repo. `google_fonts` therefore fetches Poppins **over the network
at runtime** on first launch and caches it to disk. On a cold install on a slow Kenyan
connection the app renders its first frames in Roboto and then swaps. That is a visible
font-swap on the single most important screen a new user will ever see.

### 3.2 Iconography

The family is right (§2.1). The *application* of it is not:

- **Icon badges are pure decoration.** Every Profile row and every Details row wraps
  its icon in a `primaryAccent`-tinted rounded square. Fourteen stacked rows, fourteen
  identical purple squares. Because they all share one tint, they carry **zero**
  differentiating information — the eye cannot use them to find "Payout Destinations".
  They cost 46 px of horizontal space per row and add a purple wash to the whole screen.
- **Sizes are ad hoc.** 13, 13.5, 14, 15, 16, 18, 20, 26, 36, 44 px all appear. There
  is no icon size scale.
- **The disclosure chevron is rendered at full text colour**, so it reads as heavy as
  the row's title. On iOS and in Material it is a tertiary-weight affordance.
- **Icon + label doubling.** The Post button draws a `+` *and* the word "Post". The
  sign-in button draws a login glyph *and* says "Sign in".

### 3.3 Colour — the decisive finding

**The Help24 brand and the Help24 app use different palettes, and the app's is the
wrong one.**

The brand marks in `mobile-app/branding/*.svg` contain exactly three colours:

| Brand token | Hex | Where |
| --- | --- | --- |
| Ink | `#12161A` | the `|–|` bars, the launcher-icon background (`pubspec.yaml`) |
| **Amber** | `#E8A33D` | the crossbar — *the* brand accent |
| Paper | `#F5F3EF` | warm off-white in the lockup |

The app's UI is built on `primaryAccent #6265F0` (indigo) and `secondaryAccent #22D3EE`
(cyan), on a **cool** grey `#F8F9FA`. Nothing in the brand is purple. You can see the
collision in a single screenshot: the auth sheet shows the black-and-amber logo sitting
directly above a full-width indigo button.

It gets worse under counting:

- **39 distinct hard-coded hex values** across 13 files, outside the theme
  (`Color(0xFF…)`, 63 occurrences).
- Plus `Colors.red` ×13, `Colors.grey` ×5, `Colors.black26/54/87`, `Colors.white54/70`
  — **theme-blind constants that do not change between light and dark at all.**
- **Red, amber and green are each defined twice and both definitions render on the same
  card.** `errorRed #EF4444` vs urgency `#E53935`; `warningOrange #F59E0B` vs
  `#FF9800`; `successGreen #10B981` vs `#4CAF50`. A feed card can show a `Soon` tag in
  `#FF9800` beside a `Payment Protected` tag in `#F59E0B`.
- Post-type badges are **Material 2014**: `#2196F3`, `#4CAF50`, `#9C27B0`.
- `_docs/DESIGN_SYSTEM_REPORT.md` documents the primary as `#6366F1` while the code
  says `#6265F0` — a **third** spelling.

The website team already hit all of this. `help24_website/lib/tokens.ts` carries a
block titled `STATUS_COLOR_CONFLICT` that documents the duplicate reds/ambers/greens as
a *known conflict carried deliberately, because the app does it*, and had to invent a
web-only `primary-bright #818CF8` because `#6265F0` measures 4.37:1 on dark and cannot
legally carry small text. **The app is exporting its colour debt to the website.**

Separately, the accent is not restrained. On one Discover screen `#6265F0` is the
active pill fill, the CTA fill, the Post FAB gradient, the nav active indicator, the
nav active label, the category-badge text, the "3 applied" chip and the filter dot.
Uber's Base system reserves its single accent for *"a single accent moment, not
sprinkled."* Help24 sprinkles it eight times above the fold.

### 3.4 Spacing, radius, density

Measured across the whole app:

- **19 distinct corner radii in use** — 1, 2, 3, 4, 6, 8, 9, 10, 11, 12, 14, 15, 16,
  18, 20, 22, 24, 26, 50 — across 323 call sites. A radius *system* has four or five.
- **12 distinct `EdgeInsets.all` values**, including 10, 11, 14, 26 and 28 — 11 and 26
  are off any grid at all.
- A feed card nests radius 16 (card) → 12 (thumb 10) → 8 (badge) → 6 (tag), which is
  fine in principle, but the same card sits in a screen whose pills are radius 24 and
  whose filter button is radius 12.

Density: at 412 × 915 the Discover feed shows **2.5 cards per screen**. The card is
~200–283 px tall for what is, in content terms, a title, a place, a person and a price.
Jobs shows **one card and 700 px of empty grey**.

Triple separation: every card has a **fill** (white) *and* a **1 px border** *and* a
**drop shadow**, on a grey page. Airbnb's listing card deliberately has neither border
nor shadow. Help24 pays for all three, and the result is that nothing on the screen
recedes.

### 3.5 Components

- **`PostCard` (712 lines) and `JobCard` (419 lines) are two implementations of one
  concept.** They share `FeedCardTokens` but not structure — each re-declares its own
  decoration, header row, avatar row and CTA.
  They will drift. (An earlier draft claimed they already spell money differently;
  that was wrong — `formatPriceDisplay` is the single source and it is `KES`
  everywhere. Verified on device, corrected.)
- **`ReputationTrustBlock` exists and is never used anywhere.** The rich trust block —
  rating, completed jobs, completion rate, tier, member-since — is written, tested
  against a cache, and rendered by nothing.
- **Three overlay vocabularies, unevenly used:** 82 `SnackBar`s, 24 bottom sheets,
  8 dialogs. Feedback is overwhelmingly transient and bottom-anchored, competing with
  the nav bar.
- **Generic-default tells:** `CircularProgressIndicator` as the loading view;
  `Card`/`Container` with `BorderRadius.circular(16)` everywhere; `FilledButton` with
  default Material sizing; the 100 px profile avatar with a **purple→cyan gradient and
  a coloured drop shadow**, which is the single most "AI-generated" element in the app.
- The centre Post button is the app's **only gradient** and its only coloured glow.

### 3.6 Content

Confirmed exactly as suspected, and confined to one place. Profile's rows:

| Title | Subtitle actually shipping |
| --- | --- |
| Become a Provider | Profession, contact & verified payout number |
| Payout Destinations | Where your M-Pesa earnings are sent |
| Saved | Your shortlist of posts & providers |
| Service History | Completed services, work & receipts |
| My Posts | Requests, offers & job posts |
| Promote Business | Feature a listing · campaigns, results & payments |
| Professional Profile | Sign in to build your profile |
| Notifications | Sign in |
| Location Access | Sign in |

Nine rows in a row where the second line either **describes the destination instead of
letting the destination describe itself**, or **restates the title**, or — in three
cases — says "Sign in", which is what tapping the row does anyway.

The pattern to keep is the one already used well: `My Posts → "3 active posts"`,
`Theme → "Device Default"`, `Language → "English"`. A subtitle earns its place when it
carries **state** the user cannot otherwise see. It does not earn its place by
explaining a noun.

Two more:

- `Jobs` is titled **"Job Opportunities"** and filters by **Full-time / Part-time /
  Contract / Remote**. That is Indeed's taxonomy in a Kenyan local-services marketplace.
  "Remote" for a plumbing job is meaningless, and the chips are clipped off the right
  edge with no scroll affordance.
- **Language is a promise the app cannot keep.** `assets/l10n/{en,sw}.json` hold **39
  keys**, used at **16 call sites**, in an app with ~27,700 lines of screen code.
  Switching to Kiswahili changes almost nothing. This is a trust problem, not a design
  one, and it should either be filled in or the setting should be withdrawn before
  launch.

### 3.7 Navigation

**Jobs does not deserve a top-level tab.**

- Jobs is a *filter over the same corpus Discover already shows* — `JobModel` has
  `toPostModel()` and the tab opens the same `post_detail_screen`. Discover's "All"
  already includes job posts.
- It currently holds **one listing**, and marketplace supply is the binding constraint
  right now (9 offers, 2 accounts as of this month).
- Its filter taxonomy is wrong for the product (§3.6).
- Meanwhile, the thing that *does* deserve a tab — **your activity**: your posts, your
  applications, jobs in progress, money held, receipts — has no home at all and is
  scattered between Profile rows and Post-detail sub-screens.

Secondary navigation problems:

- The centre **Post** button is a fifth nav slot that is not a destination; the index
  maths in `HomeScreen._getNavIndex()` exists purely to paper over that.
- The bottom bar is **70 px of content + safe area + 12 px padding** with 26 px icons
  and 11 px labels — noticeably taller and heavier than a Material 3 navigation bar.
- Notifications and Urgent live in Discover's header, so they vanish on every other tab.

### 3.8 Accessibility — measured, and this is the hard-fail section

WCAG 2.1 AA requires **4.5:1** for normal text and **3:1** for large text and for
non-text controls/boundaries. Computed against the shipping tokens:

| Token | Used for | On | Ratio | Verdict |
| --- | --- | --- | --- | --- |
| `lightTextTertiary #9CA3AF` | card descriptions, all timestamps, schema answers ("Opens at 7:30am"), empty-state subtitles, hint text | white | **2.54** | **fails AA *and* AA-large** |
| `lightTextTertiary #9CA3AF` | same | `#F8F9FA` | **2.41** | **fails both** |
| `successGreen #10B981` as text | the price — `KES 3,200/wk`, `Open to offers` | white | **2.54** | **fails both** |
| `warningOrange #F59E0B` as text | `Soon`, `Payment Protected` | white | **2.15** | **fails both** |
| `errorRed #EF4444` as text | `Urgent` pill, 13 px w700 | white | **3.76** | fails AA (13 px is not "large") |
| `secondaryAccent #22D3EE` | declared as `ColorScheme.secondary` | white | **1.81** | any component defaulting to it is invisible |
| `primaryAccent #6265F0` | all CTAs, all accent text | white | **4.53** | passes by 0.03 |
| `primaryAccent #6265F0` | accent text in dark | `darkCard` | **3.76** | **fails AA** |
| `darkTextTertiary #6B7280` | same tertiary role in dark | `darkCard` | **3.52** | **fails AA** |
| `lightBorder #E5E7EB` | every card boundary, every input outline | white | **1.24** | fails the 3:1 control rule |

The root cause is systemic and worth naming precisely: **these are Tailwind *fill*
colours being used as *foreground* colours.** `#10B981` is a perfectly good green to
fill a shape with; it is not a green you can set text in on white. A semantic system
needs a *fill* token and a *text* token per role, and this palette has only one of each.

Non-colour issues:

- **No `Semantics` wrappers anywhere except `FilterPill`.** The semantics dump for the
  entire post-detail screen returned **one** node with `role="button"`. The bookmark
  control, the back control and the category chip are unlabelled to a screen reader.
- **No `textScaler` handling.** Card titles are `maxLines: 2` with fixed 15 px and the
  bottom bar is a fixed `SizedBox(height: 70)`; at 1.3× system font scale these overflow.
- Icon-only controls (bell, filter, bookmark) have tooltips in one case and none in the
  others.

### 3.9 Hierarchy and the "what is this app?" test

Open Discover cold and count what competes for attention above the fold:
a 20 px "Discover", a bell, a red `Urgent` pill with its own border, a 64 px search
field, three 42 px pills, an unlabelled outlined filter square, and then a card carrying
**a blue badge, a purple badge, a grey timestamp, an amber tag, an avatar, a name, a
place, a green status phrase and a purple button**.

Nine competing elements before the user has read a single listing. The answer to *"what
can I get done here?"* is in there — `Need laundry services · Mombasa · Offer Service` —
but it is the fourth-loudest thing on its own card.

And the conversion screen is worse the other way. Post detail is **REQUEST** (bright
blue, caps, bold) + **Soon** (amber) + **Open to offers** (green, 28 px, in a 160 px
tinted box) + a *"Posted by / Alphonse Lincoln"* card with **no rating, no completed
jobs, no member-since, no verification** + a two-row Details card + **700 px of empty
space** + a purple CTA. On the screen where a stranger decides to let another stranger
into their home, the trust surface is a name.

---

# PHASE 2 — RESEARCH: the principles that apply

Not styles to copy. Principles, with the reason each one is relevant *here*.

**Uber Base — "less is more", "simple semantics", "go big".**
Base is near-black-and-white with `#276EF1` reserved for *a single accent moment, not
sprinkled*; one unmistakable primary action per screen, a solid dark button on white.
Type is a modular scale from a **14 px base × 1.125**, line height **size × 1.45 rounded
to the nearest 4**, everything on a **4 px baseline grid**, and styles named by **role,
not pixel value** — explicitly to remove decision paralysis.
→ *Relevance:* this is the exact cure for §3.3 (accent sprinkled eight times) and §3.1
(13 styles nobody uses because they are named by size).

**Apple HIG — Clarity, Deference, Depth.**
"Adornments are kept to a minimum." "The interface never competes with the content."
"Whitespace does the hierarchy work so chrome can recede."
→ *Relevance:* directly indicts the icon badges, the triple card separation, and the
green tinted budget box (§3.4, §3.5, §3.9).

**Airbnb DLS — trust is typographic, not decorative.**
The **rating gets the loudest typographic treatment in the whole system**; review counts
carry the same visual weight as price. The listing card has **no border and no shadow**
— the photo carries it. Display type sits at **22–28 px in weights 500/600**, not 700+.
→ *Relevance:* this is the answer to §3.9. Help24 does not need more badges to feel
trustworthy; it needs the trust *facts it already computes* (`ReputationTrustBlock`,
unused) rendered at a weight that matters.

**Material 3 — 48 dp minimum touch target**, regardless of the icon's optical size.
→ *Relevance:* sets the floor for the new nav and for icon-only controls (§3.8).

**WCAG 2.1 AA — 4.5:1 text, 3:1 large text and non-text boundaries.**
→ *Relevance:* §3.8 is not a matter of taste. Six shipping tokens fail.

**The synthesis for Help24.** Every one of these systems reaches the same conclusion by
a different route: **a serious product is mostly neutral, and spends colour once.** The
reason Help24 currently reads as a project is not that its components are bad — several
are very good — it is that nothing recedes. There is no background layer, because
every element is competing to be foreground.

---

# PHASE 3 — PROPOSED DESIGN DIRECTION

## 3.0 Philosophy

> **Help24 is a place where work gets done between strangers. The interface should
> disappear behind the work, and spend its one loud moment on the decision the user
> came to make.**

Four rules that resolve every question below:

1. **Neutral carries the app; the accent marks one thing per screen.**
2. **A word earns its place by carrying state, not by naming a noun.**
3. **Trust is typographic.** Facts at a weight that matters — not badges.
4. **Light is the design target. Dark is the same design, re-toned.**

## 3.1 Colour — adopt the brand you already have

**Recommendation: retire indigo/cyan; build the system on the brand's ink + amber + paper.**

This is not a fashion choice, and it is the opposite of inventing an identity. Help24
*has* an identity — `#12161A` / `#E8A33D` / `#F5F3EF` — drawn, shipped in the launcher
icon and printed on the auth sheet. The app just never adopted it. Indigo `#6265F0` has
no provenance anywhere in the brand, and it is already leaking its problems into the
website (§3.3).

It also solves the accessibility problem structurally. Amber cannot be a text colour on
white (`#E8A33D` = 2.16:1), which forces the correct architecture: **the primary action
becomes ink on white** — maximum contrast, no hue, unmistakably one action per screen,
the Uber Base move — and **amber becomes the accent that marks selection and brand
moments**, where it is paired with ink at 8.43:1.

Every value below is measured, not chosen by eye.

### Light (the default)

| Token | Hex | Contrast | Role |
| --- | --- | --- | --- |
| `surface` | `#FFFFFF` | — | cards, sheets, the page |
| `surfacePaper` | `#FAF9F7` | 1.05 vs surface | the ground behind cards |
| `surfaceSunken` | `#F4F2EE` | 1.12 | inputs, inactive pills |
| `contentPrimary` | `#12161A` | **18.18** | titles, values, ink buttons |
| `contentSecondary` | `#585F66` | **6.47** | supporting text |
| `contentTertiary` | `#686F77` | **5.09** / 4.83 paper | timestamps, meta — *replaces the 2.54:1 token* |
| `borderHairline` | `#E3E0D9` | 1.32 | felt, not seen — separation only |
| `borderStrong` | `#928D83` | **3.30** | outlined controls — meets the 3:1 rule |
| `accent` | `#E8A33D` | ink on it: **8.43** | selection, brand, the one accent moment |
| `accentInk` | `#9C660B` | **4.86** | when amber must be *text* or a boundary |
| `positiveText` / `positiveFill` | `#0B7A4B` / `#12A365` | **5.39** / 3.25 | money, completed — *text and fill split* |
| `cautionText` | `#8A5B08` | **5.86** | soon, held, pending |
| `criticalText` | `#C22B22` | **5.73** | urgent, disputed, destructive |
| `infoText` | `#1F5FBF` | **6.09** | links, informational |

### Dark (the same design, re-toned)

| Token | Hex | On card `#1B2024` |
| --- | --- | --- |
| `surface` / `surfaceRaised` / `page` | `#15191D` / `#1B2024` / `#0E1114` | — |
| `contentPrimary` | `#F2F4F6` | **14.90** |
| `contentSecondary` | `#A8B0B8` | **7.48** |
| `contentTertiary` | `#868E96` | **4.95** |
| `borderHairline` / `borderStrong` | `#2A3035` / `#6E767E` | — / **3.56** |
| `accent` | `#E8A33D` | **7.62** |
| `positive` / `caution` / `critical` / `info` | `#3DD68C` / `#F0B04A` / `#FF6B60` / `#7FB0FF` | 8.76 / 8.61 / 5.88 / 7.47 |

**Every token passes its WCAG requirement.** In dark, the primary button inverts —
`contentPrimary` fill with `page` label — so "one high-contrast action" holds in both
themes without a second design language.

**Consequences to accept before saying yes:**

- The post-type badges lose their 2014 Material colours. `Request` / `Offer` / `Job`
  become typographic (weight and case), not chromatic — which is right, because the
  card already says what it is in its title.
- Urgency collapses from two palettes to one: `criticalText` / `cautionText` / neutral.
- The purple→cyan avatar gradient goes. Initials on a neutral surface.
- The website's `tokens.ts` is generated *from* the app and will need regenerating.
  Its `STATUS_COLOR_CONFLICT` block gets deleted rather than maintained.

**If you would rather not move off purple**, the honest alternative is: keep `#6265F0`
as `accent`, but *still* do everything else — split fill from text tokens, fix the six
failing contrast values, delete the duplicate reds/ambers/greens, and stop sprinkling
the accent. That recovers maybe 70% of the gain. It leaves the logo and the UI
disagreeing, and it leaves the app looking like a well-executed template rather than
like Help24. I recommend the brand palette.

## 3.2 Typography

**Bundle Inter. Two decisions, and the second is free because of the first.**

*Bundling* is not optional independent of which face wins — §3.1 showed the app
currently downloads its typeface at runtime and swaps fonts on first launch. Ship a
subset variable `.ttf` in `assets/fonts/`, declare it in `pubspec.yaml`, drop
`google_fonts` from the theme path.

*Inter* over Poppins because: designed for screen UI, tall x-height and open apertures
that hold at 12–14 px (which is where most of Help24's text lives), a genuine weight
range, and — decisive for a marketplace — **tabular numerals**, so `KES 3,200` and
`KES 850` align in a column and a live countdown does not jitter. It is also neutral
enough to let the amber-and-ink brand do the talking, where Poppins has a personality
that competes with it.

*Alternatives considered:* **Plus Jakarta Sans** (more character, slightly less
legible small — a reasonable pick if Inter feels too anonymous); **Geist** (excellent,
but reads as "developer tool" in 2026); **system font stack** (free and fast, but
Help24 would look different on every handset, which is the opposite of an identity).

**The scale — named by role, on a 4 px grid, line height = size × 1.45 rounded to 4:**

| Role | Size / LH / Weight | Used for |
| --- | --- | --- |
| `displayS` | 28 / 40 / 600 | screen titles ("Discover") |
| `headingL` | 22 / 32 / 600 | post-detail title |
| `headingM` | 18 / 28 / 600 | section headings, sheet titles |
| `headingS` | 16 / 24 / 600 | card titles, row titles |
| `bodyL` | 16 / 24 / 400 | reading copy |
| `bodyM` | 14 / 20 / 400 | default body — **neutral colour, not grey** |
| `bodyS` | 13 / 20 / 400 | supporting |
| `label` | 13 / 16 / 500 | buttons, chips, nav |
| `meta` | 12 / 16 / 400 | timestamps, captions |
| `mono` | 14 / 20 / 500, tabular | **money, counts, countdowns** |

Ten roles, not thirteen sizes. Card titles move **15 w700 → 16 w600** (Airbnb's
"display at 500/600, not 700+"). `bodyM` stops being pre-coloured grey. Every call site
that currently writes `fontSize: 12.5` gets a role instead.

## 3.3 Iconography

**Keep Iconsax Linear. Keep `app_icons.dart` exactly as it is.** Change three things
about how icons are *used*:

1. **Delete the decorative icon badge.** Profile rows and Details rows render the glyph
   at `contentSecondary`, no tinted square. This alone removes fourteen purple squares
   from one screen and reclaims 46 px of row width.
2. **A size scale: 16 / 20 / 24, and 28 in the nav only.** Nothing else.
3. **The chevron drops to `contentTertiary`** and 20 px. It is an affordance, not
   content.

Rule: an icon appears when it is *the* identifier (nav, category, a status that repeats
in a list). Next to a text label that already says the thing, it is removed.

## 3.4 Spacing, radius, elevation

**Spacing — 4 px base, one scale, one name each:**
`xs 4 · sm 8 · md 12 · lg 16 · xl 24 · 2xl 32 · 3xl 48`
Page gutter **16** (down from 20 — buys 8 px per card at 412 px width).
Section gap **24**. In-card gap **12**.

**Radius — five values, replacing nineteen:**
`sm 8` (tags, badges) · `md 12` (buttons, inputs, thumbs) · `lg 16` (cards, sheets) ·
`pill 999` (chips only) · `full` (avatars).

**Elevation — the rule that fixes the "everything is foreground" problem:**

> A surface gets **either** a border **or** a shadow. Never both. Never neither.

- Cards on paper: **hairline border, no shadow.**
- Sheets and menus (things that genuinely float): **shadow, no border.**
- The nav bar: **hairline top border, no shadow.**

**Density target:** feed card from ~200–283 px to **~150–170 px**, which puts
**4–5 cards** on a screen instead of 2.5 — without shrinking any type.

## 3.5 Component language

- **One card.** `ListingCard` replaces `PostCard` + `JobCard`, with the type-specific
  parts injected. Ends the structural drift between two cards rendering one concept.
- **Buttons.** `primary` (ink fill / white label — one per screen), `secondary`
  (`borderStrong` outline), `ghost` (text). Heights **48 / 40 / 32**. Never a gradient,
  never a coloured glow.
- **Chips.** One `Chip` with `neutral | accent | positive | caution | critical`, one
  height (32), one radius. Replaces the ~6 bespoke pill implementations.
- **Rows.** One `AppRow` with optional `leadingIcon`, `title`, optional `value`
  (state, right-aligned, not a subtitle), optional `trailing`. Height 56, not 74.
- **Feedback.** Sheets for choices, inline for validation, snackbar **only** for
  "done, and you can undo". 82 snackbars is a smell — most are inline states wearing a
  snackbar's clothes.
- **Loading.** Skeletons that match the real layout (already done well for the feed) —
  and `CircularProgressIndicator` retired from full-screen use.

## 3.6 Navigation

**Recommendation: keep a standard bottom bar of four true tabs. Replace Jobs with
Activity. Move Post to a FAB.**

```
Discover        Activity        Messages        Profile          [ + ]
 browse          my work         talk            account          post
```

- **Discover** absorbs Jobs entirely. Jobs is already a filter over the same corpus
  (§3.7), and it becomes a chip in the filter row — with the taxonomy fixed to
  something that means something here (*Today · This week · Near me · Has photos*),
  not Full-time/Remote.
- **Activity** is the tab the product has been missing: my posts, my applications, jobs
  in progress, money held, receipts. It gives the four orphaned lifecycle screens a home
  and answers *"what is happening with my work?"* — and it is where a badge actually
  belongs, because something needing your attention is the whole point of the tab.
- **Post becomes a FAB** over Discover and Activity. It is an action, not a destination;
  making it a nav slot is why `HomeScreen._getNavIndex()` has index arithmetic. Research
  supports tab-bar-plus-FAB as long as each pattern has exactly one job — the current
  design fails that test by making the FAB *be* a tab.
- **Notifications move to the shell**, not Discover's header, so the bell does not
  disappear on three tabs out of four.

**Why not floating/pill navigation:** it costs vertical space, it floats over content
(fighting Deference), its hit targets are smaller, and it is a strong 2023–24 trend
signal — exactly the "looks AI-generated" register we are trying to leave. A plain bar
with a hairline border and generous targets is what mature consumer products do.

**Bar spec:** 64 px + safe area (from 70 + padding), 24 px icons, 12 px labels always
visible, **48 dp minimum target**, active = `contentPrimary` icon + label with a 2 px
amber underline — no tinted pill behind the glyph.

**Impact if accepted:** `home_screen.dart`, `custom_bottom_nav.dart`, `jobs_screen.dart`
(becomes a Discover filter), plus one new `activity_screen.dart` that *composes existing
screens* rather than reimplementing them. **Because there are zero named routes, no
route table has to change** — the 62 `MaterialPageRoute` pushes are unaffected.

## 3.7 Theme

Light is the default and the design target; `ThemePreference` already supports
system/light/dark and is already surfaced in Profile. Two changes:

1. **One semantic token set, two tonal values each** — `AppColors.of(context)` — so no
   widget ever writes `isDark ? X : Y` again. That ternary appears in essentially every
   widget file today and is why dark and light drift.
2. **New installs default to light**, not system. (Today the default is system, which
   means a user whose phone is in dark mode has never seen the brand's light identity.)

## 3.8 Motion

- Durations: **120 ms** state, **200 ms** transition, **280 ms** sheet. Nothing longer.
- Curves: `easeOut` in, `easeIn` out. One easing pair for the whole app.
- Keep the feed crossfade and the zero-duration-behind-splash rule — both are correct.
- **Remove** `.animate().fadeIn(300ms).slideY()` from every feed card. A list that
  animates each row on build makes scrolling feel laggy and is decoration by definition.
- Respect `MediaQuery.disableAnimations`.

---

# PHASE 4 — SCREEN PRIORITY

Ordered by (frequency × impact) ÷ regression risk.

| # | Surface | Why here | Risk |
| --- | --- | --- | --- |
| 0 | **Tokens + theme + type** | nothing else is coherent until this lands; touches no logic | Low |
| 1 | **`ListingCard`** | the single most-rendered component; kills the PostCard/JobCard split | Low–Med |
| 2 | **Discover** | first impression; answers "what is this app" | Low |
| 3 | **Bottom nav + shell** | structural; unlocks Activity | **Med** — `HomeScreen` state |
| 4 | **Post detail** | the conversion screen; where trust must appear | Med |
| 5 | **Profile** | worst offender for noise; high visit rate | Low |
| 6 | **Activity (new)** | fills the real product gap | Med |
| 7 | **Messages list** | high frequency, low current pain | Low |
| 8 | Auth, sheets, empty/error states | consistency pass | Low |
| 9 | Payment / escrow / dispute screens | **token-only**; no layout change | **High — do last, minimally** |

**Deliberately excluded from the redesign:** `payment_screen.dart`,
`approve_or_dispute_screen.dart`, `dispute_thread_screen.dart`, `mark_complete_screen.dart`,
`payout_*`, `receipt_screen.dart`. These get new tokens and nothing else. Their copy is
*safety copy* — consent, irreversibility, money — and §4 of the brief explicitly
protects it.

---

# PHASE 5 — IMPLEMENTATION PLAN

Each step is independently shippable and independently revertable.

1. **`lib/theme/tokens.dart`** — colour, spacing, radius, type, motion, icon sizes.
   Additive; nothing imports it yet.
2. **`AppTheme` rebuilt on tokens**, both brightnesses, bundled Inter. Ship it and look
   at the app: everything re-tones, nothing re-lays-out. **This is the checkpoint where
   the colour decision is proven cheaply** — if the amber direction is wrong, it is one
   file to revert.
3. **Primitives** — `AppButton`, `Chip`, `AppRow`, `AppCard`, `SectionHeader`,
   `Avatar` — built beside the existing widgets, not replacing them yet.
4. **`ListingCard`**, adopted by Discover first, Jobs second. Delete `JobCard` only once
   both render from it.
5. **Discover** — header, search, filter row, density.
6. **Shell** — nav bar, Post → FAB, notifications into the shell. Jobs → Discover filter.
7. **Activity** — composing `MyPostsScreen`, `ApplicationsScreen`, `JobStatusCard`,
   `ServiceHistoryScreen`, which all already exist.
8. **Post detail** — hierarchy, and render the trust facts (`ReputationTrustBlock` is
   already written and currently rendered by nothing).
9. **Profile** — subtitle purge, `AppRow`, icon badges out, regrouping.
10. **Messages, sheets, empty/error/loading** consistency pass.
11. **Money/legal screens** — tokens only.
12. **Consistency audit** — a test that fails on any raw `Color(0x…)`, `Colors.*` or
    off-scale radius outside `tokens.dart`, so this cannot regrow.

---

# THE "DO NOT BREAK" LIST

Nothing in Phase 5 touches any of the following. Any change that would is out of scope
and must be raised first.

**Identity & session** — `AuthService`, `AuthProvider`, `SupabaseAuthBridge`,
`auth_guard.dart`, Firebase↔Supabase token exchange, the UID-is-the-identity contract,
account-linking, email-verification pacing, `AUTH_ENFORCEMENT` staging.

**Data & backend** — every `services/*.dart` API call, `ApiConfig`, all Supabase queries
and RLS assumptions, the ranking/feed endpoints, promotions, reputation.

**Money** — payment, escrow, payout destinations and the `PAYOUT_DESTINATIONS_ENABLED`
flag, STK push, receipts, refunds, dispute flows. **Copy on these screens is frozen.**

**Lifecycle** — post creation, application, acceptance, in-progress, mark-complete,
approve/dispute, review. Status strings and transitions are untouched.

**State & structure** — `AppProvider` (2,643 lines) and its notification contracts, the
feed snapshot/generation model, `_install` vs `_splice`, the engaged-reader gate,
`NotificationStore`'s single-owner rule, the launch transaction and splash handover,
presence heartbeat, outbox, connectivity.

**Platform** — `system_bars.dart`'s single-owner rule, FCM handlers, deep links,
`location_service.dart` (and *especially* the stream I stubbed and reverted).

**Contracts that are load-bearing and easy to break by accident:**
`utils/post_ownership.dart` (one ownership rule, one CTA rule) · the four-state feed
presentation machine · "a failed fetch is never published as an empty result" ·
"null means not applicable" for reputation · `app_icons.dart`'s render-before-you-add rule.

---

# THE ONE DECISION I NEED BEFORE PHASE 5

Everything above is reversible except the colour direction, which sets the tone of every
later step. The recommendation is **adopt the brand's ink + amber + paper**, for the
reasons in §3.1 — chiefly that it is not a new identity, it is the identity Help24
already ships in its logo and launcher icon, and that it forces the accessible structure
(ink primary action, accent reserved for one moment) rather than bolting it on.

Step 2 of Phase 5 is deliberately the cheapest possible way to test that: one file,
whole app re-tones, trivial to revert.

---

# ADDENDUM A — Verified on hardware (SM-G986U, Android 13)

The audit above was written from the web renderer. It was then re-run on the
real device — a Galaxy S20+, Android 13, 1080 × 2400 @ 450 dpi — **signed in,
with the ranking engine and reputation service reachable**. That surfaced three
things the web run could not.

**A.1 The card is busier than the web run showed.** With live data a single
request card carries: `Request` badge, `Plumbing` badge, `1mo ago`, `Flexible`,
`Leak`, `Toilet`, avatar, name, `New Provider`, location, `Open to offers`,
`Offer Service`. **Twelve elements.** And the category badge and the Smart
Posting highlight chips render *identically* — `Plumbing`, `Leak` and `Toilet`
are the same chip — so nothing tells the reader which one is the category and
which two are answers. This strengthens the §3.5 case for one `Chip` with
explicit variants.

**A.2 The trust block exists, works, and leads with the wrong thing.**
`ReputationProfileSection` renders a tier label, a rating, and a five-stat grid.
All five stats carry **equal weight**: `6 Jobs Completed`, `67% Completion
Rate`, `44% Dispute Rate`, `0 Open Disputes`, `2026 Member Since`. Two problems:

- The loudest element is the tier label (`New Provider`, ~28 px), which is the
  *least* informative fact on the card. Airbnb's rule — the rating gets the
  loudest typographic treatment — is inverted here.
- **A dispute rate is rendered in the same neutral weight as a completion
  rate.** On a provider's *public* profile that is a product decision, not a
  styling one, and it should be made deliberately before launch rather than
  inherited from a stat grid. Flagging, not changing.

Also: `2026 Member Since` reads as a quantity because it sits in a grid of
quantities. "Member since 2026" is a sentence, not a stat.

**A.3 Messages is already close to right.** Avatar, name, preview, the pinned
listing in italic, date right-aligned, hairline dividers, no chrome. It needs
tokens and nothing else — which is why it sits at #7 in the Phase 4 order. One
real issue: because conversation identity is `(ordered pair, post_id)`, the
same counterparty legitimately appears several times, and the **listing context
line is the quietest element on the row** while being the only thing that
distinguishes them. The listing should outrank the date.

---

# ADDENDUM B — Phase 5 progress

Steps 1 and 2 of the plan are done and verified on hardware. The colour
direction is proven, cheaply, exactly as intended.

**Shipped**

| File | Change |
| --- | --- |
| `lib/theme/tokens.dart` | **new** — `AppColors` (a brightness-resolved `ThemeExtension`), `AppSpace`, `AppRadius`, `AppMotion`, `AppElevation`, `AppTypeScale` |
| `lib/theme/app_theme.dart` | rebuilt on tokens; one `_build` for both brightnesses; every legacy static repointed |
| `lib/widgets/custom_bottom_nav.dart` | gradient + glow + tinted pill removed; active = full-contrast content + a 2 px gold rule; `Semantics` added |
| `lib/widgets/filter_pill.dart` | selected = brand gold with ink label (8.43:1); tokens throughout |
| `lib/models/post_model.dart` | the duplicate 2014-Material urgency/type palette now routes through the theme |
| `pubspec.yaml` + `assets/fonts/` | Inter bundled at 4 weights (~1.7 MB); no more runtime font fetch |

**Verified:** `flutter analyze` — **0 errors, 64 issues, which is exactly the
pre-change baseline.** Release web build, release APK and debug APK all compile.
Installed on the S20+ as an update, so the signed-in session survived.

**Two things the checkpoint caught that code review would not have**

1. `splashFactory: InkSparkle.splashFactory` — which I had added — painted a
   solid grey block over the lower half of every settings card on Android and
   web. Removed. It was an unnecessary addition in the first place.
2. The centre button's gradient was `[accent, accent.withBlue(255)]`. The moment
   the accent stopped being indigo, that ramp ran **gold → violet**. A latent
   bug that only a colour change could ever have exposed.

**Deliberately not done yet** (they belong to later steps, and doing them now
would mean picking values twice):

- The `Request` / `Offer` badge colours and the category-vs-highlight chip
  collision — step 4, with `ListingCard`.
- `Open to offers` and the price still in green, competing with the ink CTA —
  step 4.
- Card density is unchanged at ~2.5 cards per screen — step 4.
- Profile's nine explanatory subtitles and the decorative icon badges — step 9.
- Jobs' "Job Opportunities" title and its Full-time/Remote taxonomy — step 6,
  when Jobs folds into Discover.

**Decisions taken, recorded here so they are not re-litigated**

- `AppTheme`'s flat statics survive as shims because **no single `const Color`
  can be legible in both themes** — measured across the whole amber ramp. That
  is the argument for `AppColors`, and it is why the shims are tuned
  light-first (AA on light, ≥3:1 on dark) rather than split the difference.
- Caution is **terracotta `#A8541A`**, not gold. With an amber brand accent, an
  amber status chip and a selected chip would be indistinguishable.
- `AppIconSize` already existed in `app_icons.dart` with a better scale
  (sm/md/lg/**xl** for empty states). The duplicate in `tokens.dart` was
  deleted rather than competing with it.

---

# ADDENDUM C — Phase 5 steps 3 and 4

Primitives and the unified listing card. Verified on the SM-G986U in both
themes, and — for the branches the device cannot reach — by a new test suite.

## What shipped

| File | Change |
| --- | --- |
| `lib/widgets/primitives.dart` | **new** — `AppChip`/`ChipTone`, `AppCard`, `AppRow`/`AppRowGroup`, `SectionHeader`, `MetaLine`, `MoneyLabel` |
| `lib/widgets/listing_card.dart` | **new** — the one card |
| `lib/widgets/post_card.dart` | 712 lines → a 4-line delegate |
| `lib/widgets/job_card.dart` | 419 lines → a 4-line delegate |
| `lib/widgets/marketplace_card_components.dart` | `OwnerCta` sized and de-coloured; `MarketplaceAvatar` made theme-aware |
| `lib/theme/tokens.dart` | added `navSurface` (see C.3) |
| `test/listing_card_test.dart` | **new** — 24 behavioural tests |

**Density: 283 px → ~153 dp per card.** 2.5 cards per screen became 4–5, with
no type made smaller. The photo moved from *below* the author row to a leading
72 px thumbnail, so the image column and the text column finally share vertical
space.

**Chips: up to ten candidates → at most two**, in an explicit priority order
(disclosure → live countdown → urgency → competition). Everything that loses
becomes text on a `MetaLine`, where *order* carries the meaning that identical
pills could not.

## C.1 What the screenshots caught

1. **`Karen BrinaNew Provider`** — `ReputationCompact` emits a bare `Text` for
   the no-reviews tier with no leading space; the old card had a `SizedBox`
   before it and I dropped it.
2. **`Alpho… New Provider  Momb…`** — on a card with a thumbnail the text
   column is ~240 dp, and the name and the place both ellipsised. Location
   moved to the detail line, where it reads in full and is arguably better
   placed anyway.
3. **`Starts immediately` twice.** Not a layout bug: production has a job whose
   entire `description` is the string `timeSignalChip` computes for it. The
   card now drops a description that only repeats the meta line.
4. **The owner CTA was a two-line slab.** It inherited the token layer's
   `OutlinedButtonThemeData`, whose 48 px minimum and 24 px padding exist for a
   *standalone* secondary action. It states its own size now — and it no longer
   takes the accent, because the label already says whose listing it is.

## C.2 What the tests caught

Writing the suite surfaced a duplication the redesign had inherited rather than
fixed: **lifecycle state was reported twice** — once as a status chip, and
again in the action slot, which replaces the CTA with the state for a visitor
and does the same through `OwnerCta` for the author. The status chip is gone.
The action slot is the single place a listing says where it is in its life.

One test was also simply wrong about the card (it expected an `Urgent` chip on
a listing that was no longer open). The card was right — an urgency window that
closed when the request was taken is noise — so the test changed, and a second
test now pins that behaviour explicitly.

## C.3 The regression the tests caught, measured

`system_bars_test` failed, and it was **right**. `CustomBottomNav` had been
moved to `AppColors.surface`, which equals the system navigation bar colour in
light and differs from it by one step in dark. That is a **#1B2024 bar against
a #15191D system navigation bar** — a visible seam along the bottom of every
screen in dark mode, and precisely the class of bug that test file was written
for after it was found on this same handset.

The fix is a token whose *name* is the contract: **`AppColors.navSurface`,
defined as `SystemBars.<theme>.systemNavigationBarColor`**, pinned to it by the
test. Anything painting the bottom bar reads it, never `surface`.

Verified by sampling the device framebuffer rather than by eye — the same
method the original bug was diagnosed with:

| Theme | App bar `y=2180` | System nav band `y=2396` | Status bar |
| --- | --- | --- | --- |
| Light | `#FFFFFF` | `#FFFFFF` | `#FAF9F7` (= page) |
| Dark | `#15191D` | `#15191D` | `#0E1114` (= page) |

Continuous in both. No seam.

## C.4 Two source-guard tests were rewritten, not deleted

Both asserted on the *text* of `app_theme.dart`, and one carried its own
reason: *"building a ThemeData pulls Poppins over the network"*. Bundling Inter
removed that constraint, so they now assert the **built `ThemeData`**.

This is not a convenience. A source regex can only pin the spelling of a
colour, and the seam in C.3 slipped through with **every constant intact** —
it changed which token the bar read, not what any token was worth. The same
test reading the real object catches it.

`filter_selection_test`'s "no Medium badge" guard was repointed from
`job_card.dart` to `listing_card.dart`, and now also asserts that both
delegates stay delegates, so a badge has nowhere to come back in.

## C.5 State

- `flutter analyze` — **0 errors**, 63 issues, all pre-existing.
- `flutter test` — **1,073 passing**, 0 failing.
- Verified on device: Discover, Jobs, both themes, owner and visitor CTAs.
- Not verifiable on device: no urgent request is inside its window, no
  sponsored campaign is live, and nothing is disputed. Those branches are
  covered by `listing_card_test.dart` instead.

## C.6 Still open, and deliberately

- `Request` / `Offer` type badges on the **detail** screen are still solid 2014
  Material colours — step 8.
- `Open to offers` and the price are neutral on the card now, but the detail
  screen still renders a green budget block — step 8.
- Profile's nine explanatory subtitles and its decorative icon badges — step 9.
  `AppRow` is built and waiting for them.
- Jobs' "Job Opportunities" title and Full-time/Remote taxonomy — step 6.

---

# ADDENDUM D — Phase 5 steps 5 and 6

Discover, and the navigation shell. Verified on the SM-G986U in both themes,
including the interactive states.

## D.1 A correction to Phase 1 first

§3.7 of this audit claimed *"Jobs is a filter over the same corpus Discover
already shows — Discover's All already includes job posts."* **The second half
was wrong**, and `feed_scope.dart` says so in as many words:

> `all('all', ['request', 'offer'])` — *"Requests and offers — NOT jobs, which
> have their own tab. `null` (no filter) would have been a product change
> disguised as a default."*

The first half was right — Jobs *is* a scope over one corpus, reached by one
request (`scope=jobs`), which was confirmed against production before any code
changed: `GET /feed?scope=jobs` returns exactly the listing the Jobs tab showed.
So folding Jobs into Discover uses the **same path**, with no corpus merge —
but it needed a new scope pill rather than being absorbed into "All". **"All"
still means requests and offers**, and a test now pins that, because widening
it silently would be the product change the original comment warned about.

## D.2 Discover

| Before | After |
| --- | --- |
| `Urgent` — bordered red pill, bold red label, filled red count badge | one critical-tone chip, count inside the label |
| Search: ~64 px, *"Search all posts…"* | 48 px, *"Search services and requests"* |
| Filter: 12-radius square beside 24-radius capsules, unlabelled | same height, same radius family, `Semantics` label; active = brand gold |
| *"Showing all posts for "x""*, in **italic** — the only italic in the app | `2 results` — the one thing the user cannot already see |
| 20 px gutter | 16 px |
| 3 scopes | 4 scopes (scrolling), filter pinned outside the scroll view |

`discover_screen.dart` now has **zero references to `AppTheme`** — every colour
comes from the token layer.

**Verified interactively on device:** typing `delivery` → `2 results`; applying
a category → control turns `#E8A33D`, count falls to `1 result`. The focus ring
(2 px, `contentPrimary`) is visible on the search field for the first time.

## D.3 The shell

```
        BEFORE                              AFTER
Discover Jobs [Post] Messages Profile   Discover Activity Messages Profile  (+ Post FAB)
```

- **Post is a FAB.** It was never a destination — it set a boolean that swapped
  the body and hid the bar, which is why `HomeScreen` carried translation in
  *both* directions (`index > 2 ? index - 1 : index` in, `_getNavIndex()` out).
  Both mappings are gone: **nav index == stack index**.
- **Jobs → a scope pill in Discover.**
- **Activity** is the new fourth tab, hosting `MyPostsScreen` and `SavedScreen`
  through a new `embedded` flag (body only, no second app bar), with Service
  History as a header action and the notification bell — which previously
  existed *only* in Discover's header — as the second.

**A product gap found while building it, and deliberately not papered over:**
`ApplicationService.getMyApplications` is called on every sign-in, but only to
build the set of post IDs that makes a card say "Applied". The list is
discarded. **Nowhere in the app can a provider see what they have applied to.**
Activity is where that belongs; it needs a query returning posts rather than
IDs, so it is named in the class doc and left out rather than faked.

## D.4 What the device caught

The FAB covered the last row of every list it floats over. Fixed with
`AppSpace.fabClearance`, applied to Discover, My Posts and Saved — and pinned by
a test that fails if a new scrolling surface appears under the FAB without it.

## D.5 Card states verified on hardware for the first time

The urgent post made several previously-untestable branches real:

- `237 min left` → the solid critical countdown chip, replacing the static tag
- `Urgent` chip, and the header count `Urgent · 1`
- `Offer sent` (positive, ticked), `1 applied` (neutral), `Applications (1)`
  (compact owner CTA, one line)

`distanceLabel` still does not render — **because Location Access is off on the
device**, so the coordinate is null and the card correctly omits it. Plumbing
confirmed present in `urgent_requests_screen.dart`.

**One real defect found and fixed:** a four-hour urgent window rendered as
`237 min left`. `formatUrgentCountdown` had no hours branch, which contradicted
its own documented contract — *"never a number that implies more precision than
the reader can act on"*. It now reads `3h 57m left`, with the boundary cases
tested.

## D.6 A ranking question, answered from production

*Is it right that a 3-minute-old urgent post ranks third?* **Yes.**

Two accounts share the display name "Alphonse Lincoln"; only one post is the
viewer's. Called with `explain=1`:

| Viewer | Score | Position |
| --- | --- | --- |
| Anonymous (every provider who could respond) | **35.31** | **1st** |
| The author | 10.31 | 3rd |

The difference is `ownPost: −25`, a deliberate signal whose own documentation
reads: *"Your own listing is never [something you respond to, apply for, or
hire from]. Demoted, never hidden."* The engine is correct and no backend
change is warranted. Once Activity exists — which it now does — the owner's own
listing is one tap away in the place they would look for it.

## D.7 State

- `flutter analyze` — **0 errors**, 63 issues, all pre-existing
- `flutter test` — **1,081 passing**, 0 failing (7 new across two files)
- New contract tests: `navigation_shell_test.dart` pins four destinations, the
  collapsed index space, FAB clearance and the embedded-screen contract

## D.8 Dead code left in place, on purpose

`jobs_screen.dart` (197 lines) is now built by nothing — it survives only as a
line in the `screens.dart` barrel. With it, `AppProvider.jobs`,
`hasResolvedJobs` and `jobsError` are rendered by nothing.

They are **not deleted in this step**, because `post_flows.dart:145` still calls
`appProvider.loadJobs()` after a successful application, so the data path is
live even though its only reader is gone. Untangling that means repointing the
refresh at `loadPosts()` and re-verifying that a card flips to "Applied" on
device — a separate change with its own verification, not a tidy-up to bundle
into a navigation commit.

Follow-up, in this order:
1. Repoint `post_flows`' post-apply refresh, verify the "Applied" flip on device.
2. Delete `jobs_screen.dart` and its barrel export.
3. Remove `AppProvider.jobs`, `loadJobs`, `hasResolvedJobs`, `jobsError` and the
   `jobs` slot in the error register.

---

# ADDENDUM E — Phase 5 steps 8 and 9

Post detail and Profile. Verified on the SM-G986U.

## E.1 Post detail — the conversion screen

This is where a stranger decides to let another stranger into their home. It
carried a name and an avatar.

| Element | Before | After |
| --- | --- | --- |
| Type badge | solid Material-2014 fill, white caps, w800, 1.1 tracking | typographic — tertiary caps, no fill |
| Price | green-tinted, green-bordered box, 21 px w800 **green** | neutral surface, ink, tabular |
| "Open to offers" | same celebratory green as a real price | muted — it is the *absence* of a budget |
| Author | avatar + name + one compact line (renders as **nothing** for a provider with no reviews) | avatar + name + the full trust block |
| Detail rows | tinted rounded square per row, all the same tint | plain glyph |

**`ReputationTrustBlock` is now rendered.** It was written for exactly this job
and, before this, **no screen in the app used it**. On device it shows
`New Provider` · `0 Jobs Completed` · `No Reviews Yet` — three separate facts,
so "new" reads as new rather than as bad. The ~700 px of dead space is gone,
because the screen now has something to say.

## E.2 Profile — the subtitle purge

`_SettingsTile`'s `subtitle` was **renamed to `value`**, so the type system is
what stops a description coming back. A `value` is right-aligned and can only
carry state the user cannot otherwise see.

Deleted outright: *"Profession, contact & verified payout number"*, *"Where
your M-Pesa earnings are sent"*, *"Your shortlist of posts & providers"*,
*"Completed services, work & receipts"*, *"Feature a listing · campaigns,
results & payments"*, *"Sign in to build your profile"*, and two rows whose
subtitle was literally *"Sign in"* — which is what tapping them does.

Trimmed to state: `254••••999 · the number you pay from` → `254••••999`;
`Requests, offers & job posts` → nothing until the count loads, then `15
active`; `Off · tap to turn on` → `Off`.

The profile avatar lost its **two-stop gradient and coloured drop shadow** —
the single most generated-looking element in the app, glowing indigo behind a
real photograph. It is a hairline ring now.

## E.3 "My Activity" in Profile was a repetition — removed

Raised by the user mid-review, and correct. With Activity as a tab, Profile's
`My Activity` section was a **second path, one tap deeper**, to the same three
destinations:

| Profile row | Already reachable as |
| --- | --- |
| My Posts | Activity → "My posts" scope |
| Saved | Activity → "Saved" scope |
| Service History | Activity → header action |

The section is gone, along with `_MyPostsTile` (which fetched a live post count
for a screen that no longer lists posts). **This is what makes Activity a
relocation rather than an addition: Profile got shorter by exactly what the new
tab absorbed.** It now reads identity → trust → Business → Account →
Preferences → Support, with nothing on it that is not about the account.

## E.4 What the device caught in this step

1. **Titles wrapped onto two lines.** `AppRow` gave the title and the value
   flexible space, so they split the row and "Professional Profile", "Payment
   Number" and "Location Access" each wrapped while a short value sat in acres
   of space. The title takes what it needs now; the value is capped at 128 dp
   and ellipsises.
2. **`Off · tap to turn ...`** truncated — and the instruction was redundant
   anyway, since the row is tappable and the screen it opens says what to do.
   Every location branch is state now: `On · Mombasa`, `Off`, `Denied`.
3. **The completion ring crowded the chevron.** A percentage ring, a next-step
   label and a chevron in a column sized for one. The ring is the value.

## E.5 State

- `flutter analyze` — **0 errors**, 63 issues, all pre-existing
- `flutter test` — **1,081 passing**
- Verified on device: Profile (both halves), post detail, Activity, Discover

---

# ADDENDUM F — Phase 5 steps 10, 11 and 12 (sprint close)

## F.1 The colour audit, closed

The audit opened with **39 distinct hard-coded hex values across 13 files**,
plus `Colors.red` ×13 and `Colors.grey` ×5. It closes with **four raw hexes and
one named colour outside `lib/theme/`**, every one of them deliberate:

| Site | Why it stays |
| --- | --- |
| `auth_screen.dart` ×4 | Google mandates the exact colours of the Sign-in-with-Google button |
| `launch_splash.dart` ×1 | brand ink, must match `values/styles.xml` — a file Flutter does not compile |
| `payment_screen.dart` (`Colors.amber`) | a DEV-only debug overlay, never built in release |

**Two more copies of the duplicate palettes were found while closing this out**,
beyond the two already fixed in `post_model.dart`:

- `marketplace_card_components.dart` held a **third** copy of the urgency
  palette (`#E53935` / `#FF9800` / `#4CAF50`).
- `post_screen.dart` held a **second** copy of the type-badge palette
  (`#2196F3` / `#4CAF50` / `#9C27B0`) — so the composer preview and the card it
  was previewing disagreed.

That is five hand-maintained copies of two ideas. None of them would have
failed a build or a review.

## F.2 A contrast failure found in the tier labels

`tierColor()` was a pure function over five fixed values, two of them raw hexes
picked for the light theme alone. Measured on a dark card: `#B45309` (trusted
professional) is **3.27:1** and `#6B7280` (new provider) is **3.40:1** — both
below AA, on a label whose only job is to be read. It takes a `BuildContext`
now and resolves through `AppColors`.

**Flagged, not fixed:** these are five *hues* for what is really a **ladder** —
new → rising → top rated → highly recommended → trusted professional. Five
unrelated colours say "five categories", not "five rungs", and the reader has
to learn a key. A single-hue ramp would say it without one. That is a design
decision about how Help24 presents provider standing, so it is named in the
code and left for its own pass.

## F.3 Step 12 — the guard

`test/design_tokens_test.dart` fails the build on:

- any raw `Color(0x…)` outside the allowlist above;
- any theme-blind `Colors.<hue>` (white / black / transparent excepted — those
  are absolutes, not theme choices);
- the **reappearance of a retired palette value**, by exact hex. If `#FF9800`
  is ever back in `app_theme.dart`, one of the old urgency palettes came with
  it.

The allowlist is keyed by file with a stated reason, and it may only shrink.

## F.4 Radius — a ratchet, and a sprint of its own

Still **19 distinct corner radii across 291 call sites**, against a system of
four. Converging them is a visible change at every site, spread across nearly
every file — a sprint, not a line in a token commit.

The guard therefore **ratchets rather than gates**: off-scale radii may fall,
never rise (baseline 172). A screen written today has no excuse; the backlog
gets a deadline someone chooses.

The test also fails if the count drops *well* below the baseline — a reminder
to lower it so the ratchet keeps holding the new line.

## F.5 What the last device pass caught

A live message arrived mid-verification and exposed the last inconsistency:
**the unread count was gold in the conversation list and red in the bottom
bar** — one concept, two colours, on two surfaces visible at the same moment.
Both are `criticalFill` now, which is the convention everyone already knows.

The unread *timestamp* also dropped its colour: the row already carries a red
count, so saying "unread" again in a third colour was redundant. It is weight
now.

Also fixed: Messages drew its own avatar placeholder as a **solid accent-filled
circle**, so a list where two people have no photo showed two large saturated
discs — the loudest thing on a screen made of words.

And the empty state's icon box was `surface` on `page` — **1.05:1**, which is
to say the empty state's own artwork was invisible on the screen it existed to
fill.

## F.6 State at sprint close

- `flutter analyze` — **0 errors**, 59 issues (was 64 at the start; all
  remaining are pre-existing warnings in service files)
- `flutter test` — **1,085 passing**, 0 failing (**+11** across four new files)
- Verified on the SM-G986U in both themes: Discover, Activity, Messages,
  Profile, post detail, urgent requests, the filter sheet, and the
  bottom-bar seam measured off the framebuffer

---

# ADDENDUM G — The urgent count meant the wrong thing

Raised from the device at sprint close: *"it says Urgent · 1 regardless of
whether I have already viewed the post."* Correct, and worth fixing before
launch rather than after.

## G.1 What it was doing

The count was `openUrgentPosts(...).length` — every emergency whose window was
still open. That is a true fact and a defensible one: an open emergency is
still open whether or not you have looked at it.

But it was drawn as **a red count**, and a red count means one thing to
everyone who has ever used a phone: *N things you have not dealt with yet*. So
the number never moved. Open the list, read the request, come back — still
`Urgent · 1`.

**A badge that does not respond to being looked at teaches people to stop
looking.** On an emergency surface that is the one outcome the feature cannot
afford. The shape was making a promise the data was not keeping.

## G.2 What it does now

The count is **unseen open emergencies**. Two parts, deliberately separated:

- **The entry point never decays.** `Urgent` stays in the header whether or not
  anything is new, because the screen behind it is still worth reaching.
- **The count does.** It is the part that was over-promising.

"Seen" means **the list was on screen**, not "you opened the post" — a provider
who reads the list and decides none of them are theirs has seen them, and
badging them again tomorrow would be the same failure one step later.

`UrgentSeenStore` is a `SessionScoped` `ChangeNotifier` over SharedPreferences.
It prunes against the live open set on every write, so it holds at most the
currently-open emergencies rather than growing for the life of the install, and
it clears on sign-out so the next person on the device has not "seen" anything.

Note the card's own `Urgent` chip is untouched: the *listing* is still urgent.
Only the *notification count* clears — those are different facts and now look
different.

## G.3 Verified

On device: `Urgent · 1` → open the list → back → `Urgent`. Nine tests in
`test/urgent_seen_test.dart` cover the decay, a new emergency arriving after
others were seen (the case the change exists for), pruning, persistence across
restart, sign-out, and that marking the same set twice does not churn listeners.

`flutter test` — **1,094 passing**.

---

# ADDENDUM H — THE BACKLOG SPRINT

Everything the "what is not done" section listed was taken on in one pass, at
the user's direction, before the website work begins. All seven items are
closed. Verified on the SM-G986U in both themes.

## H.1 Radius — 19 values to 5, and the guard became a gate

The ratchet fired on its own terms. `design_tokens_test` was written to fail if
the count dropped *well* below its baseline, with the note "when this fires, the
convergence sprint has landed". It landed: **off-scale radii went 172 → 0**, and
there is now no numeric radius anywhere in `lib/` outside `tokens.dart`.

**Most of the 19 were never different radii.** They were one intention written
many ways, so the sweep is mostly a reclassification rather than a retune:

- **1, 2, 3, 4, 50 and most of the 20s were PILLS** — a 4 px drag handle, a 6 px
  carousel dot, a 100 px avatar, a 20 px chip, an 18 px skeleton bar. Every one
  was a hand-computed "half my own height", and every one silently becomes wrong
  the moment the element is resized. `AppRadius.pill` says the intention and
  cannot drift.
- **24 was the SHEET radius.** Of the 22 places that round the top of a modal,
  **16 already used 24** — the app had a consistent sheet language the whole
  time, it was simply never written down.
- The rest rounded to the nearest rung by ROLE: controls to `md`, content
  surfaces to `lg`, tags to `sm`.

### The scale is five, not four — and that is the correction

The audit set out to converge on four, folding sheets into `lg`. The call sites
said otherwise, and they were right. A radius reads relative to the surface
carrying it: 16 on a 340 px card and 16 on a full-width sheet are not the same
gesture, which is why every system that has both gives the sheet a larger one
(Material 3: 28 against 12). Forcing 22 sheets to 16 would have been 22 visible
changes made to satisfy a number in a document.

`AppRadius` is now **sm 8 · md 12 · lg 16 · sheet 24 · pill 999**, and the guard
asserts exactly those five by name and value. Adding a sixth is a design
decision someone has to make deliberately.

### What the sweep found on the way

Converging the values meant reading all 291 sites, and three duplications fell
out that no amount of grepping for colour would have surfaced:

- **The sheet grab handle was hand-rolled fourteen times**, plus a public
  `SheetHandle` class in `chat_ui.dart` that four more surfaces imported, plus a
  `_SheetGrabber` in `location_experience.dart`. Three names, eighteen sheets,
  two widths (36 and 40), three colours and eight different margins — so no two
  sheets in the app opened with quite the same affordance. One `SheetHandle`
  primitive now.
- **Twelve of those copies drew the bar in the HAIRLINE border colour** —
  `#E3E0D9` on white, which measures **1.29:1**. A hairline is meant to be a
  boundary you do not notice; this is a control, and the only thing on screen
  saying the sheet can be dragged away. It was effectively invisible in light
  mode. It is `borderStrong` now (3.30:1) and carries a semantic label, which it
  never had.
- **The chat bubble's corner geometry existed twice** — once for the real bubble
  and once for `_BubblePreview`, the preview OF that bubble. They had already
  drifted: the preview closed a run with a 6 px corner where the real thing used
  4. One `chatBubbleRadius()` now, expressed in `AppRadius` with only the tail
  as a named component constant.

## H.2 "What you have applied to" — the screen that did not exist

`ApplicationService.getMyApplications` has been called on every sign-in for as
long as the app has existed, and only its post IDs were kept — enough to make a
feed card say "Applied", and nothing more. The list was thrown away. A provider
could apply to a dozen jobs and have no way, anywhere in the product, to see
what they had applied for or whether anyone had decided. The one screen that
mentioned applications is the OWNER's — who applied to *my* post — the opposite
side of the same table.

**`MyApplicationsScreen`, on Activity, between My posts and Saved.** It needed
no backend change: both halves were already in production use —
`getMyApplications` for what I sent, and `PostService.fetchPostsByIds` (the
query the Saved shortlist runs) for the listings themselves.

**The outcome is DERIVED, not stored.** The `applications` row records that you
applied, when and for how much, and nothing about the decision. The decision
lives on the post — `status` plus `selected_provider_id` — which is the same
pair the owner's applicant screen, the job lifecycle and escrow all read. An
`outcome` column would have been a second copy of that, and a second copy can
disagree: an applicant told they were hired by a row the payment flow has never
heard of. `applicationOutcomeFor()` sits in `post_ownership.dart` beside the
other listing rules, with 14 tests.

The rule that matters most: **"Not selected" is only ever said when the post
NAMES a different provider.** A listing that merely left `open` — cancelled,
archived, or assigned by a path that did not stamp the id — reads as closed.
Telling a provider they were rejected when nobody rejected them is the one error
on this screen worse than saying nothing.

Two further decisions:

- **Live first, then newest.** Strict recency put a job you lost three weeks ago
  above one you are currently being paid for.
- **Listings that are gone are COUNTED, not dropped.** `fetchPostsByIds`
  excludes archived posts, and an application outlives the post it points at.
  Those cannot be rendered — the application carries no title — so a footnote
  says how many. "I applied to five things and this shows three" is the
  confusion it exists to prevent.

**Caught on the device:** `hired` was drawn as a SOLID chip, on the reasoning
that being hired is the outcome that matters. On a real account seven of nine
rows came back hired, and seven solid green chips are not an emphasis, they are
the background — which is what `AppChip`'s own doc says ("a screen with two
solid chips has none"). Solid is reserved for `disputed`: the one state here
that is both rare and urgent.

## H.3 The tier ladder — three steps that exist, not five that do not

The backend names five rungs and the app painted each a different hue: amber,
green, blue, terracotta, grey. Five unrelated colours say "five unrelated
categories", not "five rungs of one ladder" — nothing about green tells you it
outranks blue, so the reader has to learn a key written down nowhere.

**A five-step single-hue ramp was the obvious fix and does not survive
measurement.** Across the whole amber ramp there is no set of four values that
each clear 4.5:1 as text on warm paper AND on a dark card — the same wall that
made `AppColors` necessary. A ramp failing AA on two of its rungs is the old bug
in one colour.

Emphasis carries about three steps honestly, so it carries three: **unproven**
(neutral tint, no tick) → **established** (accent tint, tick) → **top** (accent
FILL, tick). Monotone, so it reads as a ladder with no key, and the exact rung
is still named in words by `tierLabel` — the part of the design that was already
doing its job properly. Claiming five visual steps is what produced five hues.

**A trust bug fell out of it.** `TierBadge` drew the verified tick
unconditionally, so a provider who had never taken a job rendered "New Provider"
behind a verified tick — the one place in the app where the trust signal said
the opposite of the truth.

## H.4 The dispute rate — counts always, percentages only with a sample

`44% Dispute Rate`, rendered in the same size and weight as `Jobs Completed` on
a stranger's public profile. Arithmetically correct, informationally worthless:
it was 4 of 9.

The failure is symmetric, which is what makes it a rule rather than a judgement
call. 1 dispute of 2 jobs prints **50%**, which follows that provider until they
complete enough work to dilute it — on a marketplace that, per the supply
reality, has no provider with that much work. And 1 job of 1 prints **100%
Completion Rate**, a perfect record earned by a single transaction. Both are a
ratio dressed as a rate with the denominator that would let anyone judge it left
off.

So: **counts always, percentages only above a stated sample** (five completed
jobs — a product choice, not a statistical one). Below it the profile shows what
is known and claims nothing it cannot support. Nothing a client can act on is
withheld: an OPEN dispute is shown at any volume, because that is a fact about
right now rather than a rate. `0 Open Disputes` is no longer printed at all — it
is not news, and it was two metrics for one idea sitting beside a dispute rate.

## H.5 Jobs — deleting the corpus, not just the screen

`jobs_screen.dart` was built by nothing. Deleting it was the small part.

The screen was the **only reader** of `AppProvider._jobs` — a whole second
corpus with its own loader, identity gate, request sequence, error slot, disk
cache and splash prefetch. Every cold start and every refresh issued a
`fetchJobsFeed` **whose answer nothing rendered**. That is a round trip on the
critical launch path, paid on every launch, for a list no pixel depended on.

Removed: `_jobs`, `loadJobs`, `hasResolvedJobs`, `jobsError`, `isLoadingJobs`,
`AppFeature.jobs`, `FeedService.fetchJobsFeed`, `PostService.fetchJobs`,
`CacheService.saveJobs/loadJobs`, the splash prefetch, and the dead `addJob` /
`addApplicationToJob`.

**The launch work was repointed rather than simply cut.** `_warmOtherScopes`
already warmed requests and offers after the feed was on screen; it warms
**jobs** too now, so the same work makes the Jobs pill instant instead of
filling a list nobody reads.

Two things the removal exposed, both fixed as part of it:

- **`deletePost` found the author by searching the in-memory feeds.** A job
  opened from My Posts is not in `_posts`, so the lookup fell through to `_jobs`
  — and the delete worked only because that corpus was loaded on every launch.
  With it gone the button would have silently done nothing. The caller passes
  the author it is already holding now; the real enforcement was always
  server-side.
- **The filter sheet's vocabulary lost a source.** `_jobs` was its second
  feeder. The warmed scopes feed it instead — three scopes rather than one
  corpus, so a typed profession resolves against more of the marketplace than
  before.

## H.6 Kiswahili — the setting, corrected on the evidence

The audit said the Language setting "promises something the app does not
deliver". Reading the code, that was **less true than stated**: Kiswahili was
already locked at the point of choice, with a padlock and a "coming soon"
dialog. The promise had been withdrawn where a user would meet it.

Two real problems remained.

**A setting with one option is not a setting.** The row opened a sheet whose
only selectable entry was the one already selected. It is gone; the machinery,
both JSON bundles and all 14 call sites stay working, so shipping Kiswahili is
translation work plus one line.

**The picker guarded the door and nothing guarded the window.** `users.language`
is a stored server value, and both the load path and the setter accepted `'sw'`
from it — so any account carrying that value from an earlier build got exactly
the half-translated app the picker existed to prevent.
`LocaleProvider._deliverable` is the single gate now, enforced on the way IN
from storage as well as on the way out from the UI.

The coverage that justifies it is pinned by a test: **39 keys, and every
`AppLocalizations` call site inside `profile_screen.dart`** — the settings list
and nothing else, against ~27,700 lines of screen code. Switching language would
have translated the settings labels and left the user in English for the feed,
the composer, payments, escrow and disputes. If localisation ever reaches a
second file, that test fails and tells whoever wrote it to reconsider the gate.

## H.7 The composer — a route at last

`HomeScreen` held `bool _showPostScreen` and rendered the composer instead of
the tab stack. It worked, and it cost three things:

- **Back meant "abandon".** The shell dropped the whole composer on the first
  back press, from any step — while the composer's own header showed a back
  ARROW that went back one step. Two controls a gesture apart, doing opposite
  things to a half-finished post with photos attached.
- No back stack of its own.
- The FAB, the bottom bar and the shell's `PopScope` each carried a
  `_showPostScreen` term, because the shell had to keep pretending the screen on
  top of it was not there.

It is pushed now, and it owns its back behaviour: **system back mirrors the
visible back arrow**, one step at a time, leaving only from the first step where
nothing has been filled in. No confirmation dialog is needed, because nothing is
discarded. The ✕ still closes immediately — `Navigator.pop` is imperative and is
not intercepted by `PopScope`, which is exactly the distinction wanted.

It pops with `true` when a listing was created, and the caller uses that: after
posting you land on Discover to watch it arrive; after cancelling you return to
the tab you came from — which the body swap could not do, because it always
dropped you on Discover regardless.

**Two regressions the device caught immediately**, and neither would have shown
in a test: as a body swap the composer rendered inside HomeScreen's `Scaffold`
and inside its `SafeArea`, so it had neither of its own. Pushed as a route it
opened on a **black page with its title clipped under the status bar**. Both are
this screen's own now.

## H.8 Also removed, at the user's direction

**The notification bell on Activity.** It had been added on the reasoning that
notifications are mostly *about* your activity — but Discover's header already
owns it, and two bells on two tabs is one control with two homes and two unread
counts to keep agreeing. The same repetition the "My Activity" block in Profile
turned out to be.

## H.9 State at close

- `flutter analyze` — **0 errors**, 59 issues (64 at the start of sprint 1; all
  remaining are pre-existing warnings in service files)
- `flutter test` — **1,131 passing**, 0 failing (+37 since sprint 1 closed,
  across three new files and three extended ones)
- Verified on the SM-G986U in both themes: Discover, Activity (all three
  scopes), the composer route and its back behaviour, Profile, the trust block,
  the theme sheet, and a live conversation

## H.10 Noted, not fixed

One thing the device pass surfaced that is outside this backlog: **the sent chat
bubble is filled with `AppTheme.primaryAccent` (`#96620A`)** — an accent-TEXT
value used as a FILL, which is the misuse the token layer exists to prevent. It
reads muddy brown rather than brand amber with ink on top. It is a sprint-1 shim
that was repointed rather than re-decided, and it wants a decision about what a
sent bubble should BE, not a token swap.

---

# THE BACKLOG — ALL SEVEN CLOSED

This section listed what sprint 1 deliberately left alone. All of it was taken
on in the backlog sprint; **Addendum H** is the record. Kept here, with the
original framing, because the reasoning for deferring each item is part of how
it was eventually done — and because two of the seven turned out to be
different from how they were written down.

1. **Radius convergence** — 19 values → 4, across 291 call sites (§F.4).
   → **Done (§H.1)**, and it is **five**, not four. The call sites showed the
   app already had a consistent sheet radius (16 of 22 used 24) that the
   four-rung scale had no name for. Off-scale radii: 172 → 0; the guard is a
   gate now.
2. **The provider tier colour ladder** — five hues for five rungs (§F.2).
   → **Done (§H.3)**: three steps of emphasis, because a five-step single-hue
   ramp cannot clear AA in both themes. Found a trust bug on the way — a
   provider with no completed work rendered behind a verified tick.
3. **"What you have applied to"** — `getMyApplications` is called on every
   sign-in but only its post IDs are kept, so no screen anywhere shows a
   provider what they applied for. Needs a query returning posts. Activity is
   where it belongs.
   → **Done (§H.2)**: `MyApplicationsScreen`, on Activity, with **no backend
   change** — both queries were already in production use, and the outcome is
   derived from the post's own lifecycle rather than stored a second time.
4. **`jobs_screen.dart` removal** — built by nothing, but `post_flows.dart`
   still calls `loadJobs()`. Sequenced in §D.8.
   → **Done (§H.5)**, and the screen was the small part: it was the only reader
   of a whole second corpus that every cold start fetched and nothing rendered.
   That launch request is repointed at the Jobs scope pill instead.
5. **`44% Dispute Rate` on a public profile** — rendered at the same weight as
   a completion rate. A product decision, not a styling one (§A.2).
   → **Done (§H.4)**: counts always, percentages only above a stated sample.
   The failure was symmetric — the same volumes that print a damning 50%
   dispute rate also print a flawless 100% completion rate.
6. **Kiswahili** — 39 keys and 16 call sites against ~27,700 lines of screen
   code. The Language setting promises something the app does not deliver;
   either fill it in or withdraw it before launch (§3.6).
   → **Done (§H.6)**, and **this entry was wrong**. The picker already refused
   Kiswahili with a padlock and a "coming soon" dialog, so the promise had been
   withdrawn where a user would meet it. What was actually broken: a stored
   `users.language` of `'sw'` bypassed that picker entirely, and a Language
   setting with one selectable option is not a setting. (It is 14 call sites,
   not 16, and all of them are in `profile_screen.dart`.)
7. **The `_showPostScreen` boolean** — the composer is still a body swap rather
   than a route, so it has no back stack of its own. It works; it is simply not
   how the rest of the app navigates.
   → **Done (§H.7)**. It was not only an architecture smell: system back
   abandoned the whole form from any step, while the composer's own header
   showed a back arrow that went back one. Back walks the steps now.

**What is open** is named in §H.10: the sent chat bubble is filled with an
accent-TEXT value, which wants a design decision rather than a token swap.

---

# NEXT SPRINT — WEBSITE AND ADMIN DASHBOARD

The app is now the source of truth for the design language, and both web
properties are still on the palette it left behind.

**`help24_website/lib/tokens.ts` is stale by design.** Its own header says every
value "was read out of the Flutter app … when the app changes, this file is
what gets updated." It currently documents:

- `primary: "#6265F0"` and `secondary: "#22D3EE"` — both retired;
- a `STATUS_COLOR_CONFLICT` block faithfully reproducing the duplicate
  red/amber/green pairs **because the app had them**. The app does not any
  more, so that block should be deleted rather than maintained;
- `primary-bright: "#818CF8"`, a web-only value invented because `#6265F0`
  measured 4.37:1 on dark. The new `accentText` is theme-resolved, so the
  workaround is unnecessary;
- `"text-tertiary": "#6B7280"` and the surfaces, all superseded.

Worth deciding before that sprint starts:

- **Does the website adopt light-first too?** It is currently dark-first with
  light as the diff. The app just inverted that, and "one product" is the whole
  argument for this work.
- **How do tokens travel?** Hand-porting `tokens.ts` a second time guarantees a
  third drift. A generated export from `lib/theme/tokens.dart` — consumed by
  Tailwind and by the admin dashboard — would make the app the single source it
  already claims to be.
- **Inter is bundled in the app.** The website and dashboard should serve the
  same cut, self-hosted, so the three surfaces are not one webfont CDN apart.

---

