# Reference Data Architecture — Locations & Professions

> One loading contract for every controlled vocabulary in Help24.
> Code: `lib/services/reference_registry.dart`, `lib/services/location_registry.dart`,
> `lib/services/profession_registry.dart`.
> Data: `mobile-app/assets/data/*.json` → `scripts/build_reference_seed.js` →
> `supabase/migrations/088`, `089`.

---

## 1. What was there before

### Locations

`KenyaLocation.all`, a hardcoded list inside `models/post_model.dart`:

- **37 entries across 17 towns.** Kenya has 47 counties. Nyandarua, Turkana,
  Wajir, Homa Bay, Bungoma, Kisii and thirty others did not exist to the app.
- **A structural lie.** The model was a `(city, area)` tuple, so every town
  without neighbourhoods was given a fabricated area called *"Town Centre"* to
  make the tuple valid. Diani (Kwale) was filed under Mombasa; Watamu (Kilifi)
  under Malindi.
- **Two chained `DropdownButton`s.** A Material dropdown cannot be searched.
  It was tolerable at 17 items and unusable at 500.
- **O(n) on every build.** `cities` rebuilt a `Set` and a `List` on each call,
  and it was called inside `build()` in two screens.
- **Not changeable without an app release.** Adding Nanyuki meant shipping a
  new APK.
- **No coordinates, no aliases, no country dimension.**
- **No "use my location" anywhere in the posting flow.** GPS coordinates were
  attached to a post *silently*, while the label came from the dropdown — so a
  post could read "Nairobi" and carry coordinates in Nakuru. Distance sorting
  trusted the wrong one.

### Professions

Better bones, wrong size. Migration 086 already established the right idea — a
server table, a stable slug in `users.profession`, a bundled fallback, a 24h
cache — but:

- **17 professions, one flat list.** No grouping; ordering was a hand-assigned
  `sort` integer that nobody could maintain past ~50 rows.
- **Search was `name.contains(query)`.** No aliases, so a *fundi wa stima*
  searching "fundi" got nothing. No ranking, so a mid-word match tied with a
  prefix match.
- **Full table refetch every 24 hours**, whether or not anything changed.
- **No country dimension.**

---

## 2. The architecture

### 2.1 One contract: `ReferenceRegistry`

A reference dataset is vocabulary the product needs *before* it can render a
screen. It has three properties that pull against each other:

1. it must be available on the **first frame** (a picker may not spin);
2. it must work with **no network at all**;
3. it must grow **without an app release**.

The resolution order is therefore fixed and identical for every dataset:

```
bundled asset  →  device cache  →  server
(always there)    (last known)     (authoritative, versioned)
```

Each step only ever *upgrades* what is in memory, and every step may fail
silently. The worst possible outcome is the app behaving exactly like the build
that shipped — never an error, never an empty list.

### 2.2 Versioning is what makes the server step cheap

Every payload carries an integer `version`, and `applyPayload` refuses anything
older than what is loaded. That single rule makes the three sources safe to
combine in any order, and it makes the daily sync nearly free: the client reads
**one row** from `registry_versions` (a few bytes) and only pulls the table when
the number went up. Sync cost stays flat as the datasets grow from hundreds of
rows to tens of thousands.

### 2.3 Search: `SearchIndex<T>`

Runs on **every keystroke with no debounce**, because a debounce is latency you
choose to add.

- **2-character prefix buckets.** Every token of every entry (name, each word of
  the name, each alias, each word of each alias) is bucketed, so a query of 2+
  characters scans candidates rather than the corpus. A short result set falls
  back to one bounded full scan so pure-substring hits ("ndo" in "Kandara") are
  never lost.
- **Memoised last query.** Flutter rebuilds freely; the same query returns the
  same `List` instance.
- **Prefix-first ranking**, with one deliberate exception: an **exact alias**
  match outranks a partial name match. "msa" is exactly what people call
  Mombasa, and it must not lose to Msambweni for sharing three letters.
- **Diacritic/punctuation folding** in one place, so "Murang'a", "muranga" and
  "MURANGA" are one string to every dataset.

### 2.4 Data lives in JSON assets; SQL is generated

`scripts/build_reference_seed.js` reads the assets and emits migrations 088 and
089. **The migrations are never hand-edited.** Maintaining the same data twice
guarantees eventual disagreement, and a disagreement means the app resolves a
stored value one way and the server another — precisely the bug a controlled
vocabulary exists to prevent. The generator also *validates*: duplicate ids,
duplicate names, orphaned areas, unknown categories and any dropped migration-086
id are build errors, not production surprises.

---

## 3. Locations

**479 places**: all 47 county headquarters, all 47 counties, every major town,
and the neighbourhoods of Nairobi, Mombasa, Kisumu, Nakuru, Eldoret and Thika.
93 carry a coordinate. Coordinates are **never invented** — a missing one simply
excludes that entry from GPS snapping, which is the honest behaviour.

### The storage contract (unchanged)

`Place.storageLabel` reproduces the exact string shape the app has always
written to `posts.location`: `"Westlands, Nairobi"` or `"Naivasha"`. Every
existing post, every `ilike '%city%'` filter and every card keeps working
untouched. No FK was added from `posts` to `locations` — it would reject legacy
rows and GPS-named places the registry has never heard of, both legitimate.

### "📍 Use current location" — the fallback ladder

```
1. reverse geocode          → "Nyali, Mombasa"   best; needs network
2. snap to nearest town     → "Voi"              WORKS FULLY OFFLINE
3. return coordinate unnamed→ user names it      never a dead end
```

Rung 2 is why this is reliable in Kenya rather than in a demo: the platform
geocoder needs data; a bundled dataset of towns with coordinates does not.

A geocoded name is also **reconciled** against the registry — when the geocoder
says "Nyali" and the registry knows Nyali, the canonical entry wins, so the
stored label speaks the same language the filters search in. Every failure mode
(permission denied, blocked, service off, no fix, unnamed) maps to a distinct
sentence that ends by pointing at the manual list. **Posting is never blocked by
location.**

### Coordinate precedence on a post

`map pin → chosen location's coordinate → null`.

The device's own position is deliberately no longer a fallback. It used to be,
which is how a post labelled "Nakuru" ended up carrying the coordinates of
wherever the poster was standing. A chosen place supplies its own coordinate
(its own, or its parent city's), so label and pin can no longer contradict each
other.

---

## 4. Professions

**482 professions across 34 categories** — skilled trades, construction, home
services, automotive, cleaning, beauty, health, education, IT, digital/emerging,
creative, media, photography, videography, agriculture, hospitality, logistics,
security, manufacturing, business, finance, legal, engineering, architecture,
government, NGO, religious, sports, entertainment, events, childcare, pets,
environment, other.

- **Alphabetical inside each category.** Browse order is `(category sort, name)`,
  not the hand-assigned `sort` integer — the only ordering a person can predict,
  and it stays correct no matter what is inserted later.
- **Aliases carry Kiswahili and local usage**: *fundi*, *mama fua*, *boda*,
  *mkulima*, *kinyozi*, *wakili*, *mjengo*, *seremala*, *mshonaji*.
- **White collar / blue collar / freelance / emerging are TAGS, not categories.**
  A Software Engineer is all three of the last ones and none of them is its
  taxonomy. Tags are inherited from the category unless overridden, so
  "freelance" is searchable without stamping flags onto 482 rows.
- **Icons are inherited from the category.** 34 glyphs, not 482 — while the
  well-known trades keep the exact icon they have always had.
- **`weight`** breaks ties so "electric" leads with Electrician, not Electrical
  Engineer.

### Backward compatibility

All 17 ids from migration 086 are present with byte-identical names, so every
value already in `users.profession` still resolves. Migration 089's
`ON CONFLICT` updates *only* the new columns, so an admin's edit to a name,
icon, sort or active flag is never clobbered. `users.profession` gains no
constraint — legacy free text keeps rendering verbatim and simply counts as an
incomplete field, exactly as before.

---

## 5. Why this scales

| Pressure | Answer |
| --- | --- |
| 500 → 50,000 entries | Bucketed search index; precomputed browse rows; `ListView.builder` |
| Daily sync cost | One version row read; full pull only on a bump |
| A new town / trade | One row + a version bump. No app release |
| A new **country** | New JSON asset, re-run the generator, set `countryCode`. **No Flutter change** |
| Offline / fresh install | Bundled asset is the floor; every later step is an upgrade |
| Server down, table missing, migration not applied | Indistinguishable from normal use |
| Vocabulary drift between GPS and filters | GPS names are reconciled against the registry |
| Data maintained in two places | It is not — SQL is generated from the asset |

## 6. Adding a country (the whole procedure)

1. `mobile-app/assets/data/locations_ug.json` — same shape, `"country": "UG"`.
2. Country-scope any profession that only exists there with `"cc": "UG"`.
3. `node scripts/build_reference_seed.js`.
4. Apply the regenerated SQL.
5. `LocationRegistry.instance.countryCode = 'UG'`.

No model change, no picker change, no query change.
