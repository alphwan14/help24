HELP24 — GOOGLE PLAY SCREENSHOT SET
Captured 25 September 2026 from the live Android build (com.help24.help24)
on a Galaxy S20+ (SM-G986U, 1080x2400), over ADB.

--------------------------------------------------------------------------
THE RULE THIS SET WAS BUILT UNDER
--------------------------------------------------------------------------
Every pixel inside the phone is the real app. No screen was mocked up,
re-typed, recoloured or rearranged. No feature, number, listing, status,
review or payment state was invented. Where the product does not do
something yet, the set does not suggest that it does.

The only things added are OUTSIDE the app: the background, the device
frame, the headline, the subheadline and the category label.

--------------------------------------------------------------------------
THE SIX, AND WHY EACH ONE IS HERE
--------------------------------------------------------------------------

01-discover                                          [ Discover feed ]
    Headline   "One feed for every kind of help"
    Sub        "Requests, offers and jobs — from fundis to tutors —
                posted by people nearby."
    Shows      The marketplace itself: the All / Requests / Offers / Jobs
               filters, search, and three live listings — a plumbing
               request in Eldoret, a welding offer in Mombasa with photos
               and M-Pesa, and a Swahili tutoring request in Mombasa.
    Why first  It is the only screen that explains what Help24 *is* in one
               look, and it shows both sides of the market at once: someone
               asking, and someone offering.
    Note       The feed is scrolled one card down from the top on purpose.
               The top listing at capture time was in Kampala, Uganda,
               which reads wrong for a Kenya-first product. Nothing was
               edited — the feed was simply scrolled past it.

02-post                                        [ Post composer, step 1 ]
    Headline   "Ask for it, or offer it"
    Sub        "Request a service, list a skill you have, or hire for a job."
    Shows      The three entry points the app actually offers: Request a
               Service, Offer a Service, Post a Job.
    Why        This is the clearest single statement of the two-sided
               model. One screen, three verbs, no explanation needed.

03-secure-service                            [ "Secure this service" ]
    Headline   "Payment held until the work is done"
    Sub        "Service cost, platform fee and total — all shown before
                you pay."
    Shows      The real pre-payment screen for a live KES 2,500 request:
               service cost, platform fee, total to secure, the M-Pesa
               authorisation notice, and the app's own protection wording.
    Why        This is Help24's central idea — money is held, not handed
               over — and the screen states it in the product's own words.
    IMPORTANT  This is the IDLE state, before anything is paid. It was
               reached by opening the screen and stopping there. No payment
               was initiated. See LIMITATIONS below.

04-job-status                                [ Job status & payment ]
    Headline   "Know exactly where a job stands"
    Sub        "Payment and completion tracked step by step, for both sides."
    Shows      The two trackers the app keeps per job — Payment (Required
               → Sent → Protected → Payout Pending → Payout Released) and
               Completion (In Progress → Requested → Awaiting Approval →
               Approved) — plus the timeline.
    Why        It is the mechanism behind the promise in 03, made visible.
    Note       This job genuinely has no payment secured against it, and
               the screen says so in an amber notice. That was left in
               deliberately. Choosing a job with a fuller payment state
               would have implied more M-Pesa maturity than exists.

05-messages                                            [ Chat thread ]
    Headline   "Every conversation stays with its job"
    Sub        "Agree the details in one thread — and see when they arrive."
    Shows      A real conversation about the dog-training request, pinned
               to that job by the banner at the top, ending in the app's
               "Arrived" confirmation card and arrival message.
    Why        The job-linked thread and the arrival confirmation are
               things a general chat app does not do. This is the screen
               that shows Help24 is not just a listings board.

06-service-records                       [ Service History → My Work ]
    Headline   "A record of every job you finish"
    Sub        "Completed work, payment status and a receipt for each one."
    Shows      Completed jobs with their locations, payment state
               (Payout processing / Payment protected) and a Receipt on
               each row.
    Why        It closes the story: the work gets done, and it leaves a
               record. Useful to a provider, and the clearest signal to a
               reviewer that this is a transactional product, not a
               noticeboard.

--------------------------------------------------------------------------
LIMITATIONS — WHAT IS DELIBERATELY NOT SHOWN
--------------------------------------------------------------------------
* No completed M-Pesa transaction. No receipt body, no transaction ID, no
  "payment successful" state, no STK confirmation. M-Pesa is not fully
  integrated, so none of that appears anywhere in the set.
* No ratings shown as a selling point, no download counts, no review
  counts, no testimonials, no awards, no "#1", no "fastest", no
  "guaranteed", no platform-wide statistics, no store badges, no
  "Download now" style calls to action.
* The figures on 06 ("6 completed jobs", "KES 54,300") are this one
  account's real in-app values. They are not platform totals and must not
  be presented as such.
* Profile and Professional Profile were dropped from the set. Both show a
  real email address and a face photo. The Messages LIST was dropped for
  the same reason (several face photos).
* One avatar remains visible small in 01 and 05 — it is the account
  owner's own profile photo, at roughly 20-30px in the final asset. If you
  would rather it were not published at all, say so and it can be
  redacted or those two screens re-shot from a different account.
* Third-party names still appear as they do in the app (Karen Brina,
  Mercy Wanjiku). This was a deliberate choice to keep the capture
  faithful; no face photos or contact details of other users are shown.

--------------------------------------------------------------------------
HOW THE CAPTURES WERE MADE
--------------------------------------------------------------------------
* adb exec-out screencap -p, straight off the device at 1080x2400.
* Do Not Disturb was switched on so no notification could land mid-capture,
  and switched back off afterwards.
* The Samsung Edge Panel handle was overlaying the left edge of every
  screen, so `settings put global edge_enable 0` was set for the capture
  pass and restored to 1 afterwards. Nothing else on the phone was changed.
* No change was made to the Help24 app, its code, or its data. No
  application was accepted, no payment initiated, no post created.

THE ONE EDIT INSIDE THE PHONE, AND WHY
  The Android status bar (top 84px) is replaced with a clean, consistent
  one: 10:30, wifi, signal, battery. This is OS chrome, not Help24 UI.
  It was done because SystemUI demo mode is ignored by Samsung One UI, so
  the captures otherwise carried six different clock times, six battery
  levels and a Do Not Disturb icon. The band's background colour is not a
  guessed hex — it is sampled from row 80 of each capture itself, so it is
  that screen's own real background. No app pixel is touched.

--------------------------------------------------------------------------
DESIGN SYSTEM
--------------------------------------------------------------------------
Taken from the app, not invented for the campaign:
  Ink          #12161A   brand ink            (tokens.dart contentPrimary)
  Canvas       #0E1114   dark page            (tokens.dart page)
  Paper        #F5F3EF   off-white            (the brand lockup's own)
  Amber        #E8A33D   the brand crossbar   (tokens.dart accentFill)
  Typeface     Inter 400/500/600/700, the same files the app bundles
  Lockup       assets/brand/help24-lockup-on-dark.svg, used unaltered

Layout is identical across all six: lockup top-left, category label,
headline, one-line subhead, then the device on the same baseline at the
same size every time. One warm light source sits behind the device; there
are no other gradients, badges or decorative shapes.

--------------------------------------------------------------------------
FILES
--------------------------------------------------------------------------
final/              1080 x 1920  PNG  — upload these to the Play Console
hi-res/             2160 x 3840  PNG  — decks, investor PDFs, print
raw-captures/       1080 x 2400  PNG  — untouched device captures
contact-sheet.png   2920 x 3664  PNG  — all six together, for review
_build/             the generator (build.js, contact.js, render.sh) and
                    the intermediate HTML; safe to delete, kept so the set
                    can be regenerated when the app changes.

To rebuild after replacing anything in raw-captures/:
    cd _build && node build.js && ./render.sh && node contact.js
