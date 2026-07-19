# Help24 — The Location Experience
### Design specification · v1 · July 2026
Status: **proposal — approved architecture pending review. No implementation yet.**

---

## 0. Thesis

In a messaging app, location is an attachment. In Help24, location is **the coordination layer of a job**: every transaction ends with two people physically meeting. The current flow fails because it borrows the attachment mental model (Photo / Document / Location → subtypes → durations), which is a taxonomy of *data formats and TTLs* — implementation vocabulary.

Strip every Help24 scenario to first principles and only two irreducible intents exist:

1. **"The job is HERE."** — a *place*: the gate, the stalled car, the ward entrance. Often deliberately NOT the sender's GPS position.
2. **"I am COMING."** — a *presence in motion toward a destination*, which ends when they arrive. Duration is not a user decision; "until I arrive" is the intent.

Plus one facilitator that today doesn't exist at all:

3. **"Where exactly?"** — a *request* for either of the above.

Evidence from production: in the Medical Transport conversation a user typed **"Available, Pin location please"** and received a bare, unlabeled coordinate pin a day later. One screenshot, three product failures: requesting has no affordance (prose negotiation), the reply could only be GPS-position (no way to pin the actual pickup gate), and the resulting bubble has no name, no distance, no way to navigate to it. The redesign exists to make that exchange impossible to need.

Every provider scenario (plumber travelling, rider delivering, caregiver heading over, mechanic to stranded car, electrician confirming arrival) is intent #2. The customer-gate scenario is intent #1. Six personas, two verbs — that compression is the design.

---

## 1. Information architecture

```
LOCATION EXPERIENCE
│
├── Entry points (4)
│   ├── Composer [+] → "Location" row (verb copy: "Share or request location")
│   ├── Contextual chips above composer (highest-intent moments, 1 tap)
│   │     ├── "On my way"        · shown to provider when chat's post has a place
│   │     └── "Share location"   · shown when the other party requested it
│   ├── Inline [Share] CTA on a received Request card
│   └── Chat-header live strip → opens active journey map (while sharing/watching)
│
├── Intent sheet (ONE sheet, 3 verbs, role-aware ordering — never a second sheet)
│   ├── On my way            → Journey confirm (full-screen map)
│   ├── Send a place         → Place picker   (full-screen map)
│   └── Request location     → sends immediately (no further UI)
│
├── Full-screen surfaces (geography = full-screen; choices = sheet; never half-map sheets)
│   ├── Place picker         · draggable pin, label field, "My position" snap
│   ├── Journey confirm      · destination + route preview, big single CTA
│   └── Live journey map     · shared by sender ("sharing") & receiver ("watching")
│
├── Thread artifacts (message cards — no generic map bubbles)
│   ├── Place card           · label, distance-from-me, [Navigate], mini-map
│   ├── Journey card (live)  · avatar marker, "2.1 km away · moving", [Stop] (sender)
│   ├── Arrival receipt      · journey card's terminal state: "Arrived 14:32 ✓"
│   └── Request card         · "asked for your location" + [Share now] [Later]
│
└── System states — permission, GPS-acquiring, accuracy, offline, reconnect,
    battery, destination-less journey, arrival detection (§7)
```

**Role awareness (Help24's structural advantage — WhatsApp cannot do this):** every chat is bound to a post (`Conversation.postId`), the post knows its owner and its coordinates (`Post.latitude/longitude`), so the client can compute who is travelling and who is hosting: for a Request/Job post the owner is the customer and the responder is the provider; for an Offer post it's inverted. The intent sheet **orders** verbs by computed role (traveller sees *On my way* first; host sees *Send a place* first). Ordering, not hiding — either party can do either thing. Zero configuration, zero new data.

---

## 2. User journeys

**J1 — Mechanic → stranded driver (the canonical Help24 journey)**
Driver posts "Flat tire, Highway 101". Mechanic opens chat. Chip above composer: **[ On my way ]** (post has coordinates). One tap → Journey confirm: map shows his position and the pin, "Sharing until you arrive · stops automatically". Tap **Start**. Thread gets a live Journey card; driver's chat header shows "Denis is on the way · 4.8 km". Driver taps it anytime for the full map. At 100 m for 60 s the journey auto-completes → card mutates to **"Arrived 14:32 ✓"** — a permanent receipt in the thread. Total provider effort: **2 taps**. Today: 4 taps, a blind duration guess, no destination concept, no arrival, and the customer refreshes a dumb bubble.

**J2 — Customer sends the exact gate**
Caregiver asks where to come. Customer: [+] → Location → **Send a place**. Full-screen map opens **already centered on the post's coordinates** (not their GPS — they might not be at the property). Pin is draggable; label field: *"Black gate next to Mzuri Kiosk"*. Send. Caregiver's card shows the label, "3.2 km from you", and **[Navigate]** — one tap into Google Maps turn-by-turn (free `geo:` intent, no API cost).

**J3 — "Where exactly?" without prose**
Rider needs the delivery point. [+] → Location → **Request location** — done, no further UI. Customer sees a Request card with **[Share now]** → jumps straight into Place picker. The Ojars scenario, solved: request is 1 tap, response is 2.

**J4 — Live share without a destination (caregiver reassurance, no fixed pin)**
*On my way* with no resolvable destination degrades in place: the Journey confirm swaps "until you arrive" for a duration control (30 m / 1 h / 2 h). Same surface, adaptive — capability preserved, but duration appears **only** in the one case where it's genuinely the user's decision.

---

## 3. Interaction flow

```
[+] ──► Intent sheet (spring in, GPS warm-up starts silently in background)
          │
          ├─ On my way ──► JOURNEY CONFIRM (full-screen)
          │                 destination := post pin → last Place card → else duration mode
          │                 [ Start sharing ] ──► thread: Journey card (live)
          │                                       header strip on BOTH sides
          │                 sharing ends: auto-arrival | "I've arrived" | Stop | 2h cap
          │                                └──► card mutates → Arrival receipt
          │
          ├─ Send a place ──► PLACE PICKER (full-screen)
          │                 center := post pin → else my GPS  · drag anywhere
          │                 [◉ My position] snap-back · label (optional) · [ Send ]
          │                                └──► thread: Place card
          │
          └─ Request location ──► sends request card immediately, sheet closes
                            recipient card [Share now] ──► PLACE PICKER (pre-consented)
```

Decision economics: the current flow forces **three sequential decisions before any value** (attach type → location type → duration), the riskiest one (duration) decided blind before seeing a map. The new flow: **one verb, then at most one decision made in full context** (pin position — with the map on screen; or Start — with destination visible). Common outcomes in 2 taps; the chips make the single most common outcome 1 tap.

GPS acquisition starts the moment the intent sheet opens, so full-screen surfaces appear already-located. (Today `_sendCurrentLocation` blocks the send behind a cold GPS fix.)

---

## 4. Screen & component hierarchy

**Screens (3 new/replacing, all full-screen routes):**

```
LocationIntentSheet          — modal sheet, 3 rows, role-ordered; replaces _showLocationOptions
PlacePickerScreen            — map · center-fixed pin overlay · accuracy ring ·
                               [◉ my position] · label field · Send bar · state banners
JourneyScreen                — one screen, two modes:
  · confirm mode             — destination card, route line (straight-line P1), Start bar
  · live mode                — traveller avatar marker + destination pin, telemetry bar
                               ("2.1 km · updated 5 s ago"), [Stop / I've arrived] (sender)
                               (replaces _FullScreenMapScreen for journeys; plain place
                                viewing keeps the existing full-screen map)
```

**Thread cards (replace the single generic location bubble):**

```
PlaceCard        = MapThumbnail(lite, AbsorbPointer) + label row + distance row + [Navigate]
JourneyCard      = MapThumbnail(live) + status row (pulse dot · "moving · 2.1 km away")
                   + progress states + [Stop sharing] (sender only) → ArrivalReceipt
ArrivalReceipt   = compact, mapless: "✓ Arrived · 14:32" + journey duration
RequestCard      = compact, mapless: icon + "Wamboi asked for your location"
                   + [Share now] [Later]
```

**Shared primitives:** `MapThumbnail` (lite-mode, AbsorbPointer — the gesture-arena fix is a hard invariant), `DistanceLabel` (haversine, client-side, zero API cost), `LiveDot` (pulse, reduced-motion aware), `StatusStrip` (chat-header live indicator), `IntentRow`, `StateBanner` (permission/accuracy/offline).

**Naming is user-language everywhere:** *On my way · Send a place · Request location · Choose on map · I've arrived · Stop sharing.* Banished: "current location", "live location 15/30/60", any word that describes the mechanism instead of the intent.

---

## 5. Motion

| Moment | Motion | Why |
|---|---|---|
| Intent sheet in | 260 ms spring, slight overshoot | present, not sluggish; matches existing sheets |
| Row → full-screen | 320 ms container transform; row icon morphs into the map pin | continuity: "that choice became this place" |
| Pin settle (picker) | drop + one soft bounce + light haptic | confirms the pin is *placed*, not floating |
| Journey start | CTA morphs into header strip | the action visibly becomes the ongoing state |
| Live avatar | 2 s pulse ring, marker position eased 300 ms between fixes | alive without jitter |
| Card → receipt | 220 ms crossfade + height collapse | the journey visibly *concludes* in-thread |
| Reduced motion | all transforms → 150 ms fades; pulse → static LIVE badge; haptics kept | a11y parity |

Nothing loops except the live pulse; nothing moves that isn't state.

---

## 6. States (empty · loading · error)

| State | Behaviour |
|---|---|
| Permission denied | Inline panel inside picker/journey — illustration, one line of copy, [Open settings]. Never a toast dead-end. Map still shows post pin (viewing needs no permission). |
| GPS acquiring | Surfaces open instantly on last-known/post location; shimmering accuracy ring + "Finding you…". Send never blocked behind a spinner — pin placement doesn't need GPS at all. |
| Poor accuracy (>100 m) | Banner: "Your signal is approximate — drag the pin to the exact spot." Accuracy ring drawn honestly. |
| Offline — place | Send queues with clock badge ("Will send when online") — matches chat's existing offline behaviour. |
| Offline — journey | Refuse start honestly: "Live sharing needs a connection." Never fake a live state. |
| Live interrupted | Both sides: card shows "Reconnecting… last update 2 min ago" + timestamp. Auto-resume. Watcher never stares at a silently frozen marker. |
| Battery < 15 % (sender) | Pre-start note: "Live sharing uses extra battery." Informed, not blocked. |
| No destination for journey | Degrades to duration mode (§2 J4) — never an error. |
| Arrival edge | Auto-arrive = 60 s dwell inside 100 m (GPS-drift guard); manual [I've arrived] always available; 2 h safety cap with extend prompt at T-10 min. |
| Empty label | Card falls back to "Pinned location" + distance. Reverse-geocoded names are a P3 nicety (Geocoding API — costs money; labels are free and more human). |

---

## 7. Accessibility

- **Maps are invisible to screen readers — every card carries a full text equivalent** as its semantic label: "Live location: Denis is 2.1 kilometres away, moving toward you, updated 5 seconds ago." All actions (Navigate, Stop, Share now) are plain buttons outside the map surface.
- Live updates announce politely at **meaningful thresholds only** (started, < 500 m, arrived, interrupted) — never the 8-second tick.
- Stop sharing: ≥ 48 dp, always on-screen in journey mode, first in traversal order after the map.
- No colour-only signals: live = pulse **+ "LIVE" label + icon**; arrived = check **+ text**; all copy meets contrast in both themes; map style follows app theme (day/night) so cards don't glare in dark mode.
- Type scales to 1.3× without card truncation (distance line wraps under label).
- Touch: center-fixed-pin picker (drag the *map*, not the pin) — motor-friendlier than pin dragging and immune to the platform-view gesture arena.

---

## 8. Why this beats the current design (decision by decision)

| Decision | Current | Proposed | Rationale |
|---|---|---|---|
| Hierarchy root | data types (Photo/Doc/Location) → subtypes → TTLs | three user verbs | users think in intentions; the job lifecycle *is* the IA |
| Sheets | 2 nested sheets, 6 terminal options | 1 sheet, 3 rows | nested-modal fatigue killed; each row is a complete thought |
| Duration | blind upfront choice, always | only when no destination exists | "until I arrive" is the real intent; TTL was implementation leaking through |
| Destination | concept absent | first-class, auto-filled from the post | the system already knows where the job is — asking is disrespectful |
| Requesting | prose ("Pin location please") | Request card + inline response | observed production failure, eliminated |
| Choosing a spot | impossible (GPS only) | Place picker, post-centered, labeled | the gate ≠ my GPS; labels beat coordinates |
| Map container | 2 sheets → blind send | choices in sheets, geography full-screen | maps need room; half-map sheets create the exact gesture-arena class of bug just fixed |
| Thread artifact | one generic 260×140 bubble | Place/Journey/Receipt/Request cards | a location has a *job to do*; arrival receipts become trust artifacts alongside payment protection |
| Ending a share | wait for TTL | auto-arrival + I've arrived + Stop + cap | professionalism is visible closure, not expiry |
| Role | symmetric menu | role-aware ordering from post data | Help24's structural advantage; zero config |
| ETA/distance | none | haversine distance now; Routes API ETA later | value today at zero API cost; billable precision only when justified |

**Cost honesty:** everything in P1–P2 uses only the already-enabled Maps SDK (free native loads) + client math. Routes API (real ETA), Geocoding (place names) are explicitly deferred and flagged as billable.

**Schema deltas required (flagged, not executed):** message `label` (text), `destination_lat/lng`, `arrived_at`, and type `location_request` — additive, follows the numbered-migration convention (would be 085+), RLS pattern unchanged (`auth.jwt() ->> 'user_id'`).

**Backend/FGS note:** journey mode beyond app-foreground requires an Android foreground service (`foregroundServiceType="location"`) + Play policy declaration — a P2 decision gate, designed-for but not required by P1 (foreground-only journeys already cover the sitting-in-chat case).

---

## 9. Phasing (when implementation is approved)

- **P1 — the verbs.** Intent sheet, Place picker, Place/Request cards, journey-as-improved-live (manual arrive, no FGS), header strip, states, a11y. Client + 1 migration.
- **P2 — the presence.** Auto-arrival, contextual chips, FGS for background journeys, reconnect states.
- **P3 — the polish.** Routes API ETA (billable, needs key allow-list update), reverse-geocoded names, journey route polyline.

*Invariants for implementers: lite-mode thumbnails always wrapped in AbsorbPointer; no API key in source; every new surface ships with its permission/offline/accuracy states, not after.*
