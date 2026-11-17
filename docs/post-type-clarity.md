# Post types people can't get wrong

November 2026. Branch `feat/post-type-clarity`, migration 145.

## The problem

People picked the wrong kind of post. "Edger here anyone in need of plumber"
went up as a **Request**; it is a provider advertising, an **Offer**. On the
feed both kinds sat under "Request" and "Offer" in the same grey, so nobody
could tell at a glance, and customers were invited to "send an offer" to a
plumber advertising himself.

What the system knew before this work (read from code and from production on
2026-11-17):

- One table, `public.posts`; `type` is `request | offer | job` (49 / 25 / 2
  live). The app inserts posts straight into Supabase. The NestJS backend has
  no create-post endpoint.
- The type was picked on step 0 of the composer from three equal cards named
  after the database ("Request a Service", "Offer a Service", "Post a Job"),
  with nothing preselected.
- There is no stored role. "Provider" is derived: a confirmed profession plus
  a phone (`ProviderReadiness`). `users.role` is only `user` / `admin`.
- `posts.category` is free text. The picker reads the server `categories`
  table (32 rows, each with an icon key); requests and offers can also type a
  custom name (13 of the 39 names in use). The 482 professions in 34 groups
  describe a person's trade, not a post's category.
- Nothing is sent to providers when a request is posted. The only "providers
  told" path is the admin's manual Request rescue (`request_match`
  notifications, capped). Offers received are real: `applications` rows, each
  pushing `provider_applied` to the author.
- RLS let the author change any column, the type included, at any time. The
  app never offered it. The admin console could not change a type.

## What changed

### 1. One plain question (`screens/post_screen.dart`)

Step 0 is "What are you posting?":

- **I need help**: someone to do a task, a repair or a service for you.
- **I offer a service**: you do this work and want people nearby to hire you.
- **Hiring for a job** (smaller, below): a position with regular pay, like a
  house help or a shop attendant.

Accounts with a confirmed profession start on "I offer a service", everyone
else on "I need help". The profile this phone last saw answers before the
first frame (`ProfileSnapshotCache`); a late network answer never overrides a
choice already made. Tapping an answer selects it and moves on.

**Jobs stay a separate kind.** They are a different thing: an employment
relationship with an employment type, a monthly salary and a start date, no
photos, a curated category list and their own Discover tab. Merging them into
requests would put "full-time house help, KES 15,000/month" through a task
form that asks "When do you need it?". What they were missing was a sentence
saying what makes something a job, so a one-off task does not get posted as
one; the third answer now carries it. Volume is low (2 of 76 posts), so the
answer is quieter than the other two rather than equal to them.

### 2. A nudge when the words say the other kind

`utils/post_intent.dart` reads the title (on the title step) and the title
plus description (on the preview step). When the other kind scores strictly
more, a card says "This sounds like you're offering a service. Post as an
offer?" (or "...you need help. Post as a request?") with **Post as an offer**
and **Keep as a request**. It never blocks "Post Now".

Switching keeps the category, title, description, location, map pin, photos
and any typed amount, and lands on the step after the title in the new
journey, so the person walks forward through answers already filled in.
Category answers are cleared, as on any change of kind. Switching to an offer
in care or in-home work asks for the vetting check first, as picking that
category in the offer journey does.

**The phrase lists are in `mobile-app/lib/config/post_intent_phrases.dart`**,
in English, Kiswahili and Sheng, in two strengths:

- a *phrase* says what the person is doing ("we offer", "anyone in need of",
  "tunatoa", "natafuta", "looking for") and counts 2;
- a *hint* is a word both kinds use that only leans one way ("fundi wa",
  "niko na", "available", "need a") and counts 1.

So "Natafuta fundi wa fridge" is a request (2 to 1), and "Fundi wa stima,
niko na experience" is an offer (two hints, nothing against). Matching is
whole words, case and punctuation ignored, longest phrase first ("natafuta
kazi", looking for work, beats "natafuta"). A tie says nothing. The file's
header explains how to edit it; `test/post_intent_test.dart` holds real
phrasing and should gain a line for every phrase that fixes a real post.

### 3. Fixing the type after posting

**The author**, on the post screen: "Wrong type? Change to an offer" (or
request), confirmed in a dialog, while the listing is open, nobody has been
chosen and nobody has responded. A job never switches here.

**Admins**, on the listing page in the console
(`/dashboard/marketplace/requests/:id`, now linked from the offer and job
lists too): a "Listing type" card with the kind in the app's words, **Change
type** (to either other kind; a job needs an employment type) with a reason,
and every change so far with who made it and why. Any open listing with
nobody chosen can be reclassified, including one people have responded to
(the dialog says how many; their responses stay).

**Migration 145** is the authority for both:

- `trg_posts_type_change` (BEFORE UPDATE OF type) applies the author's rules
  to anything that is not service_role, and on every change tidies what only
  one kind carries: an offer or job gets urgency `flexible` and loses
  `is_urgent` / `urgent_expires_at`; each journey's reserved answer
  (`_when`, `_availability`, `_start`) is dropped when it belongs to another
  kind. The vetting guard (135) runs after it and re-judges the listing as
  its new kind, so an unverified author cannot turn a request into a
  care-work offer.
- `trg_posts_type_change_log` (AFTER) writes one `post_type_changes` row per
  change: `owner` (the author's uid), `admin` (admin id, email at the time,
  reason) or `system`.
- `admin_reclassify_post(admin, post, type, employment_type, reason)`,
  service_role only. It checks the admin is active, the listing is open with
  nobody chosen and not hidden by moderation, a job has an employment type,
  the reason is 5 to 500 characters, and takes the vetting verdict itself
  (the guard skips service_role). The console calls it from a server action
  after `/admin/me`, the same shape as the partner actions (128). **No
  backend route, so no backend deploy.**

The app shows the server's copy at once: on the post screen, in the Discover
list on screen (an edit, not an install), and in My Posts
(`AppProvider.editedPosts`, merged like `createdPosts` and
`archivedPostIds`).

### 4. Cards say who needs what (`widgets/listing_card.dart`)

"Needs help", "Offering" and "Hiring" (`PostType.kindLabel`), each in its
type's text tone (info, positive, accent). The detail badge, Saved and the
composer preview use the same words.

### 5. "Finding help" after a request (`screens/finding_help_screen.dart`)

After a request is posted the composer is replaced by a moment built from the
logo: the two ink bars (customer and provider) slide in from the sides, the
amber crossbar (escrow) settles between them and breathes, and the line reads
"Finding {category} near {location}…" from the post itself ("help" for Other,
"you" with no place). After about 2.6 seconds it settles: "Your request is
live. We'll notify you when providers send offers." and **View your post**.
The close button returns to Discover, as before.

Plain `AnimationController`s, four boxes, fades written into the colours (no
Opacity layer), theme tokens only (`contentPrimary`, `accentFill`). Under the
phone's reduce-motion setting the mark is still and the words change without
a fade. Offers and jobs keep the toast.

## Why there is no "Sent to 12 providers"

Nothing is sent anywhere when a request is posted, so any number there would
be invented. To make one true would take:

1. automatic fan-out at post time: match providers to the request
   (trade/category through the registry, distance where both have
   coordinates; the console's `lib/provider-matching.ts` already does this),
   apply the Request rescue limits (never the author, once per request, at
   most 3 a day per provider), and push `request_match` to them;
2. a home for it: posts are inserted from the app, so either a backend
   endpoint the app calls after inserting, or a database trigger plus a
   worker, writing a per-request record of who was told;
3. the app reading that record back for the count.

**Recommendation: not now.** It is a backend feature, against the freeze, and
supply is thin: 9 users have a confirmed profession, so the honest number
would usually be 0 to 2, which reads worse than saying nothing. The calm
state promises only what is real (`provider_applied` pushes the author when a
provider sends an offer). Revisit with supply; it belongs on
docs/later-with-traction.md.

## Verification

- Flutter: 1782 tests in the WSL mirror (the 3 known environmental failures),
  including `post_intent_test`, `finding_help_test` (copy, no digits ever on
  screen, settles and stops animating, reduce motion never runs a ticker),
  `post_type_switch_test`, `listing_card_test`.
- Migration 145, dry run on production inside one DO block that ends in
  RAISE (nothing kept), as each real role: author request to offer and back
  (urgency and `_when` tidied), author refused for a job, for a listing with
  an application and for an unvetted care offer, title-only edit untouched,
  another user 0 rows, anon refused, authenticated cannot call the admin
  function; admin to offer with an application, to job (refused without an
  employment type), back to request, refused for a short reason, an assigned
  listing, an unvetted care offer and an unknown admin; one audit row per
  change with the right actor. 17/17.
- Admin: `tsc` clean, 195 unit tests (`lib/listing-type.test.mjs` new), e2e
  "listing type" section 9/9 in a real browser against the fake stack.
- Owed: a phone check on the S20+ once the patch is published (step 0
  preselect for a provider account, the nudge on "Edger here anyone in need
  of plumber", the switch on a real listing, the finding-help moment with
  animations on and off).
