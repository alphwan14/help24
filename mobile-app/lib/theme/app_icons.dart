import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';

import 'app_theme.dart';

/// THE HELP24 ICON LANGUAGE.
///
/// ── Why this file exists ────────────────────────────────────────────────
/// Before this, icons were chosen at the call site. That produced three
/// problems no single screen could see on its own:
///
///   1. TWO FAMILIES, UNBOUNDED. Iconsax (geometric outline, hairline
///      stroke) and Material (whose `*_rounded` variants are visually FILLED
///      and much heavier) were mixed inside the same list rows. Stroke
///      weight in Flutter is baked into the glyph — both families are icon
///      FONTS, so there is no `strokeWidth` to equalise. The only way to
///      standardise weight is to standardise FAMILY.
///   2. OVERLOADED GLYPHS. One glyph meant several unrelated things:
///      `briefcase` was the Jobs tab AND "Become a Provider"; `flash_1` was
///      "Promote Business" AND "Urgent requests"; `card` was BOTH directions
///      of money flow (see the money section below).
///   3. NO SEMANTIC NAMES. `Iconsax.archive_1` at a call site says nothing
///      about what it represents, so the next screen re-picked from scratch.
///
/// ── The rule ────────────────────────────────────────────────────────────
/// ICONSAX LINEAR is the Help24 product UI family. It is the same design
/// language shadcn/ui gets from Lucide — 24px grid, geometric, one uniform
/// stroke, no ornament — and it already defined the bottom navigation, which
/// is the most brand-bearing icon surface in the app. A Lucide port would
/// have been a THIRD family and a full re-map of 700+ call sites for a
/// near-identical visual result. The design language is what matters here,
/// not the package name.
///
/// MATERIAL SURVIVES IN EXACTLY TWO PLACES, both deliberate and bounded:
/// the server-driven trade vocabulary in `utils/icon_keys.dart`
/// (`plumbing`, `electrical_services`, `handyman`, …), whose keys are
/// persisted SERVER SIDE so a row added in SQL keeps rendering on an older
/// build and for which Iconsax has no equivalent alphabet at all; and the
/// directional chrome at the end of this file. Everything else in the
/// product UI comes from here.
///
/// ── Outline vs filled ───────────────────────────────────────────────────
/// Iconsax ships six styles per glyph. The bare name is Linear (outline) and
/// the `5` suffix is USUALLY Bold (filled). Help24 uses outline for rest
/// state and bold ONLY to mark a selected tab or an engaged toggle — never
/// for decoration. Pairs sit next to each other below so they cannot drift.
///
/// ── NEVER TRUST AN ICONSAX NAME. LOOK AT IT ON A DEVICE. ────────────────
/// The numeric suffixes are not a reliable style axis, and some codepoints
/// have no glyph at all. Verified by rendering the whole set on an
/// SM-G986U — every one of these was a name that looked obviously right and
/// drew something else:
///
///   `star_1`          a HALF star (the diagonal reads as "disabled")
///   `star5`           a SHOOTING star, not bold `star` — `star1` is bold
///   `star2`, `star3`  BLANK. No glyph. Silent, invisible failure.
///   `refresh_square_2` BLANK.
///   `chart_success`   a chart card with a tick, not a rising trend
///   `clock_1`         a WRISTWATCH, which says nothing about history
///
/// `flutter analyze` cannot catch any of this: every one of those names
/// compiles, and a blank glyph is not an error — it is just nothing on
/// screen. Before adding a token, RENDER IT. The cheap way is a throwaway
/// entry point that draws every token in a grid with its name under it,
/// built with `flutter build apk --debug -t <that file>` and read on a real
/// handset; that is how each line above was found.
///
/// ── How to add one ──────────────────────────────────────────────────────
/// Name the CONCEPT, not the picture: `AppIcons.payoutDestination`, never
/// `AppIcons.wallet`. If two concepts want the same glyph, at least one of
/// them is wrong — that is the check that catches an overload before it
/// ships.
class AppIcons {
  const AppIcons._();

  // ── Primary navigation ────────────────────────────────────────────────
  // Rest/selected pairs. The bottom bar is the only place the bold variants
  // are allowed.
  static const IconData discover = Iconsax.discover;
  static const IconData discoverActive = Iconsax.discover5;

  /// The Jobs tab. `briefcase` now means WORK and only work — the provider
  /// enrolment action that used to share it moved to [provider].
  static const IconData jobs = Iconsax.briefcase;
  static const IconData jobsActive = Iconsax.briefcase5;

  /// The Activity tab: the user's OWN work — what they posted, what they
  /// saved, what they have done. Shares the briefcase with [jobs] on purpose,
  /// and only because [jobs] stopped being a destination: a job listing is now
  /// a scope inside Discover, so nothing else in the navigation claims work.
  static const IconData activity = Iconsax.briefcase;
  static const IconData activityActive = Iconsax.briefcase5;

  static const IconData messages = Iconsax.message;
  static const IconData messagesActive = Iconsax.message5;

  static const IconData profile = Iconsax.profile_circle;
  static const IconData profileActive = Iconsax.profile_circle5;

  // ── Identity & account ────────────────────────────────────────────────
  static const IconData account = Iconsax.profile_circle;
  static const IconData person = Iconsax.user;
  static const IconData signIn = Iconsax.login;
  static const IconData signOut = Iconsax.logout;

  /// A service provider — both the ROLE and the act of taking it on
  /// ("Become a Provider", and the counterparty marker on a service record).
  /// A PERSON being approved, not a briefcase: the briefcase belongs to
  /// [jobs], and sharing it made the enrolment row read as a second Jobs
  /// entry. Person + tick is the whole proposition — you, verified,
  /// hireable.
  static const IconData provider = Iconsax.user_tick;

  // THREE MARKS MEAN "APPROVED" AND THEY ARE NOT INTERCHANGEABLE. Each owns
  // a different surface, which is what stops them collapsing into noise:
  //   [provider]         person + tick — WHO does the work
  //   [verifiedProvider] rosette       — the badge beside a NAME
  //   [verified]         shield        — a SAFETY claim (payout proven, tier)

  /// The rosette badge that sits beside a verified provider's name.
  static const IconData verifiedProvider = Iconsax.verify;

  // ── Marketplace & listings ────────────────────────────────────────────
  static const IconData myPosts = Iconsax.document_text;
  static const IconData search = Iconsax.search_normal;
  static const IconData filter = Iconsax.filter;

  /// A filter that matched nothing — the empty state says to widen it, not
  /// that the app is broken.
  static const IconData filterEmpty = Iconsax.filter_remove;

  /// How far away a post is ("2.3 km"). A ROUTE, not a map pin: [location]
  /// already means "where", and this tag answers "how far".
  static const IconData distance = Iconsax.routing;

  /// People who applied to a listing.
  static const IconData applicants = Iconsax.people;
  static const IconData applicantsActive = Iconsax.people5;

  /// Shortlist. Iconsax draws `archive_1` as a BOOKMARK RIBBON, so this is
  /// the same mental model as the Material bookmark it replaces — the app
  /// previously used three different Material bookmark variants for the
  /// unsaved state alone.
  static const IconData saved = Iconsax.archive_1;
  static const IconData savedActive = Iconsax.archive_15;

  /// Time-critical demand. Lightning keeps the meaning it is genuinely best
  /// at — speed and urgency — now that promotion no longer competes for it.
  static const IconData urgent = Iconsax.flash_1;

  /// Paid visibility. A rising arrow — growth, not lightning: the promotion
  /// surface is a campaigns-and-results console ("Get discovered"), and a
  /// bolt read as "instant/boost" while also colliding with [urgent].
  ///
  /// `trend_up` rather than `chart_success`, which on a device turned out to
  /// be a chart card with a tick on it — that says "report approved", not
  /// "make this grow". `status_up` (bars + arrow) reads as well but carries
  /// more detail than a 20px list row wants.
  static const IconData promote = Iconsax.trend_up;

  /// A listing — a service someone OFFERS. Also the "Offer a Service" post
  /// type, which used to be a lightbulb: `lamp_charge` read as "idea", and
  /// the thing being created here is a shopfront, not a brainwave.
  static const IconData listing = Iconsax.shop;

  /// The "Request a Service" post type — a written brief of what you need.
  static const IconData postRequest = Iconsax.document_text;

  /// What kind of work a post is filed under.
  static const IconData category = Iconsax.category;

  /// The money field on a post.
  static const IconData price = Iconsax.money;

  // ── Campaign analytics ────────────────────────────────────────────────
  static const IconData impressions = Iconsax.eye;

  /// Taps on a promoted listing. A TOUCH, not a mouse cursor — Help24 ships
  /// to phones only, so a pointing device is a metaphor from someone else's
  /// product. (`finger_cricle` is Iconsax's own spelling.)
  static const IconData taps = Iconsax.finger_cricle;

  static const IconData campaignBudget = Iconsax.box;
  static const IconData schedule = Iconsax.calendar_1;

  /// Any percentage metric — campaign click-through, provider completion
  /// rate. One glyph on purpose: to a reader they are the same kind of fact,
  /// and a percent sign says so without needing the label.
  static const IconData rate = Iconsax.percentage_square;

  // ── Provider track record ─────────────────────────────────────────────
  /// How long someone has been on Help24.
  static const IconData memberSince = Iconsax.calendar_tick;

  /// A provider with no history yet ("New on Help24"). Deliberately NOT a
  /// sparkle: `auto_awesome` has been absorbed by AI product language, and
  /// it never said "new member" in the first place. A person being added
  /// does.
  static const IconData newMember = Iconsax.profile_add;

  /// THINGS THAT ALREADY HAPPENED — a job's event log, a recent search.
  ///
  /// A clock with a REWIND arrow, which is the one shape that separates it
  /// from [pending] (a thing still being waited on). Iconsax has no such
  /// glyph: `clock_1` is a wristwatch, which on a device said "watch", not
  /// "history". A plain clock would have collided with [pending] outright.
  /// One of the sanctioned Material conventions — see the chrome section.
  static const IconData history = Icons.history_rounded;

  // ── Work & jobs ───────────────────────────────────────────────────────
  static const IconData profession = Iconsax.briefcase;
  static const IconData application = Iconsax.task_square;
  static const IconData jobInProgress = Iconsax.timer_1;
  static const IconData completedWork = Iconsax.tick_circle;
  static const IconData serviceHistory = Iconsax.receipt_item;
  static const IconData review = Iconsax.star;

  /// `star1`, NOT `star5`. The bold star is the one place Iconsax's suffix
  /// convention breaks: `star5` draws a SHOOTING star, which shipped to the
  /// feed as a gold smear beside every rating until a device caught it.
  static const IconData reviewFilled = Iconsax.star1;

  // A STAR IS THE ONE GLYPH THIS FILE LETS TWO CONCEPTS SHARE, and it is a
  // considered exception rather than an oversight. "Rated" and "preferred"
  // are the same idea to a user, the two never appear on the same screen
  // (there are no ratings on Payout Destinations), and every alternative for
  // "default" — a tick, a medal, a crown — reads as something else entirely.
  // The names stay separate so a future change to one does not silently move
  // the other.

  /// The action: make this the default payout destination. OUTLINE, because
  /// it is not set yet — the screen previously drew the action and the state
  /// with the same outline star, so they were indistinguishable.
  static const IconData defaultChoice = Iconsax.star;

  /// The state: this IS the default. Filled, so "set" reads at a glance.
  static const IconData defaultChoiceSet = Iconsax.star1;

  // ── Money ─────────────────────────────────────────────────────────────
  // DIRECTION IS THE WHOLE POINT. `Iconsax.card` previously marked BOTH the
  // number a client pays FROM and the number a provider is paid TO — one
  // glyph for opposite directions of money flow, on a surface where getting
  // that backwards costs someone real money. It was also a plastic bank card
  // in a market that pays by M-Pesa phone number.

  /// Outbound, client side: the number the client PAYS FROM.
  static const IconData paymentNumber = Iconsax.money_send;

  /// Inbound, provider side: the verified destination earnings are SENT TO.
  /// `wallet_check` was already the app's own choice for the "Open Payout
  /// Destinations" button — only the tiles disagreed with it.
  static const IconData payoutDestination = Iconsax.wallet_check;

  static const IconData earnings = Iconsax.money_recive;
  static const IconData payment = Iconsax.empty_wallet;
  static const IconData receipt = Iconsax.receipt_item;

  /// THE MONEY-IS-SAFE LOCK. Funds held until the work is approved, and by
  /// extension every "Payment Protected" / "Pay securely" mark in the
  /// checkout flow. A lock rather than a bank building: the promise Help24
  /// makes is that the money is HELD safely, not that a bank is involved.
  ///
  /// Distinct from [locked], which is the access-gated lock. Two locks, two
  /// jobs — the payment flow previously used one Material lock for both, so
  /// "your money is protected" and "you cannot open this yet" looked the
  /// same.
  static const IconData escrow = Iconsax.lock;

  /// The STK prompt arriving on the buyer's handset. A phone WITH a message
  /// on it — [device] alone is just a handset and does not say that
  /// something was sent to it.
  static const IconData stkPrompt = Iconsax.device_message;

  /// A payment window that ran out. Not [error] — nothing failed, the clock
  /// simply expired and the buyer can start again.
  static const IconData expired = Iconsax.timer_pause;

  // ── Trust & safety ────────────────────────────────────────────────────
  static const IconData verified = Iconsax.shield_tick;

  /// Gated: needs authentication, or is not unlocked yet. Distinct from
  /// [escrow], which is specifically money being HELD — same idea, but they
  /// appear in different places and must not be renamed into each other.
  static const IconData locked = Iconsax.lock_1;

  static const IconData biometric = Iconsax.finger_scan;
  static const IconData dispute = Iconsax.judge;
  static const IconData report = Iconsax.flag;

  // ── Communication ─────────────────────────────────────────────────────
  static const IconData chat = Iconsax.message;
  static const IconData send = Iconsax.send_2;
  static const IconData call = Iconsax.call;

  /// Email. Named for what it IS, not for Iconsax's filename — `Iconsax.sms`
  /// draws an ENVELOPE, and the old `sms` name had it labelling the email
  /// verification banner, which read as a contradiction at the call site.
  static const IconData email = Iconsax.sms;

  /// An email address that has been confirmed.
  static const IconData emailVerified = Iconsax.sms_tracking;
  static const IconData notifications = Iconsax.notification;

  // ── Notification kinds ────────────────────────────────────────────────
  // `models/app_notification.dart` maps ~33 server notification types to a
  // glyph. It was a second icon registry in its own right, and every entry
  // was a FILLED Material `*_rounded` — the single heaviest block of visual
  // mismatch against the outline UI around it. The rows need to stay
  // scannable, so near-neighbours get genuinely different marks rather than
  // all collapsing onto [success].

  /// Someone applied to your job.
  static const IconData applicantNew = Iconsax.user_add;

  /// An applicant pulled out.
  static const IconData applicantWithdrawn = Iconsax.user_remove;

  /// The provider says the work is done and wants it reviewed.
  static const IconData completionRequested = Iconsax.clipboard_tick;

  /// The client accepted the work. A thumbs-up rather than another tick:
  /// this is a person approving a person, and the list already has several
  /// ticks in it.
  static const IconData approved = Iconsax.like_1;

  /// The hold came off the money. Pairs with [escrow] as its exact opposite,
  /// which is why it is an OPEN lock and not a second wallet.
  static const IconData escrowReleased = Iconsax.unlock;

  static const IconData evidenceRequested = Iconsax.document_upload;

  /// A reputation badge was earned.
  static const IconData badge = Iconsax.medal_star;

  static const IconData profileUpdated = Iconsax.user_edit;
  static const IconData securityAlert = Iconsax.security_safe;
  static const IconData maintenance = Iconsax.setting_4;
  static const IconData appUpdate = Iconsax.arrow_circle_up;
  static const IconData supportTicket = Iconsax.ticket;

  // ── Messaging ─────────────────────────────────────────────────────────
  static const IconData mute = Iconsax.volume_slash;
  static const IconData unmute = Iconsax.notification_bing;
  static const IconData more = Iconsax.more;
  static const IconData blockUser = Iconsax.profile_delete;
  static const IconData clearChat = Iconsax.broom;
  static const IconData searchNoResults = Iconsax.search_zoom_out;

  /// The composer's send control. An UP arrow, not [send]'s paper plane:
  /// this button sits at the end of the input and pushes the draft upward
  /// into the thread, which is the gesture the whole row describes.
  static const IconData sendMessage = Iconsax.arrow_up_2;

  /// Open the attachment tray from the composer.
  static const IconData addAttachment = Iconsax.add_circle;

  // A THIRD BOUNDED EXCEPTION, and the reasoning is the user's not the
  // library's. Chat carries cross-app conventions people already read
  // fluently — the delivery ticks, the pin, the reply arrow mean the same
  // thing in every messenger they have used. Swapping them for unfamiliar
  // equivalents would cost comprehension to buy family purity, which is the
  // wrong trade on the screen where Help24 deals get agreed. Iconsax also
  // ships no pin at all, so that one has nowhere else to go.
  //
  /// Written locally, not yet acknowledged by the server.
  static const IconData messageSending = Iconsax.clock;
  static const IconData messageSent = Icons.done_rounded;
  static const IconData messageDelivered = Icons.done_all_rounded;
  static const IconData pinned = Icons.push_pin_rounded;
  static const IconData reply = Icons.reply_rounded;

  // ── Location ──────────────────────────────────────────────────────────
  static const IconData location = Iconsax.location;
  static const IconData locationConfirmed = Iconsax.location_tick;
  static const IconData locationOff = Iconsax.location_slash;
  static const IconData currentLocation = Iconsax.gps;

  /// Device location is off or was refused — distinct from [locationOff],
  /// which is a PLACE with no coordinate.
  static const IconData currentLocationOff = Iconsax.gps_slash;
  static const IconData route = Iconsax.routing_2;

  // Place kinds in the location picker — a city, an area and a town are
  // different SIZES of place, and the picker reads far faster when the rows
  // say so before the text does.
  static const IconData placeCity = Iconsax.building_4;
  static const IconData placeArea = Iconsax.map_1;
  static const IconData placeTown = Iconsax.location;

  // ── Support, legal & settings ─────────────────────────────────────────
  static const IconData help = Iconsax.message_question;
  static const IconData support = Iconsax.headphone;
  static const IconData legal = Iconsax.document_text;
  static const IconData language = Iconsax.language_square;

  // Appearance
  static const IconData themeSystem = Iconsax.autobrightness;
  static const IconData themeLight = Iconsax.sun_1;
  static const IconData themeDark = Iconsax.moon;

  // ── Status ────────────────────────────────────────────────────────────
  static const IconData success = Iconsax.tick_circle;
  static const IconData successFilled = Iconsax.tick_circle5;
  static const IconData pending = Iconsax.clock;
  static const IconData warning = Iconsax.warning_2;
  static const IconData error = Iconsax.close_circle;
  static const IconData info = Iconsax.info_circle;
  static const IconData offline = Iconsax.wifi_square;

  /// Deliberately taken out of service — a retired payout destination, a
  /// closed listing. Not [error]: nothing went wrong.
  static const IconData retired = Iconsax.slash;

  static const IconData unreachable = Iconsax.global_refresh;
  static const IconData empty = Iconsax.document;

  // ── Actions ───────────────────────────────────────────────────────────
  static const IconData add = Iconsax.add;

  /// The centre "Post" button. Deliberately NOT [add]: this is a 26px white
  /// glyph on a filled accent circle, and at that size on that ground the
  /// Iconsax hairline plus goes weak. A plus is two strokes in any family,
  /// so nothing is lost in cohesion by taking the heavier one — and this is
  /// the app's primary action, which should be the boldest mark on screen.
  static const IconData compose = Icons.add_rounded;
  static const IconData dismiss = Iconsax.close_circle;
  static const IconData refresh = Iconsax.refresh;
  static const IconData delete = Iconsax.trash;
  static const IconData copy = Iconsax.copy;
  static const IconData edit = Iconsax.edit_2;
  static const IconData expandFull = Iconsax.maximize_3;
  static const IconData show = Iconsax.eye;
  static const IconData hide = Iconsax.eye_slash;
  static const IconData camera = Iconsax.camera;
  static const IconData gallery = Iconsax.gallery;

  /// Something clipped to a message or a dispute — the ACTION button and the
  /// "evidence uploaded" notification are the same idea, so they share one
  /// glyph rather than drifting into two paperclips.
  static const IconData attachment = Iconsax.paperclip;

  /// A PDF or text document in a dispute thread.
  static const IconData fileDocument = Iconsax.document_text;

  /// Any other uploaded file.
  static const IconData fileGeneric = Iconsax.document_1;

  /// A photo that has been chosen and accepted.
  static const IconData photoConfirmed = Iconsax.gallery_tick;

  /// Free-text the user writes about themselves — a profile bio, a note.
  static const IconData notes = Iconsax.note_1;

  /// The job is done AND the money has landed. The one place Help24 allows
  /// itself a flourish, because it is the moment the whole product exists
  /// for — and a trophy still reads instantly without it.
  static const IconData celebrate = Iconsax.cup;

  /// A post that carries no photo. Kept distinct from [imageBroken] because
  /// the two say different things to a user deciding whether to retry.
  static const IconData imageMissing = Iconsax.gallery_slash;

  /// A photo that exists but failed to load.
  static const IconData imageBroken = Iconsax.gallery_remove;
  static const IconData device = Iconsax.mobile;

  // ── Platform chrome: the sanctioned Material exception ────────────────
  // These are not product iconography, they are OS affordances — the marks
  // the platform itself trains users on for "go back", "this row opens
  // something", "this leaves the app". Iconsax's equivalents are hairline
  // and read as decorative at 18–20px, which is wrong for a control.
  //
  // The exception is closed: this list is all of it. Its value is being
  // PINNED — the app previously mixed `chevron_right` (18 sites) with
  // `chevron_right_rounded` (9), `close` (7) with `close_rounded` (10), and
  // `refresh` (10) with `refresh_rounded` (5).
  static const IconData disclosure = Icons.chevron_right_rounded;
  static const IconData back = Icons.arrow_back_ios_new_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData expand = Icons.keyboard_arrow_down_rounded;
  static const IconData collapse = Icons.keyboard_arrow_up_rounded;

  /// A bare selection tick — a list row that is chosen. Not [success], which
  /// is a circled mark reporting that something COMPLETED.
  static const IconData check = Icons.check_rounded;

  /// The empty half of a single-choice row. Pairs with [successFilled], so
  /// the chosen and unchosen states are the same circle at the same weight —
  /// which is the whole job of a radio control.
  static const IconData unselected = Icons.radio_button_unchecked;

  /// The step a progress track is currently on — a filled dot inside a ring,
  /// sitting between [unselected] (not reached) and [successFilled] (done).
  static const IconData currentStep = Icons.radio_button_checked;

  /// This opens outside Help24 (browser, dialler, maps).
  static const IconData externalLink = Icons.open_in_new_rounded;

  // [history] is also Material, for the same reason as the chat ticks: the
  // clock-with-rewind-arrow is a convention people read instantly and
  // Iconsax has nothing equivalent. It is declared up in the track-record
  // section, beside the concept it serves.

  // ── Debug-only ────────────────────────────────────────────────────────
  // Behind `kDebugMode` / the dev-harness flag, so these never reach a real
  // user. They are named here anyway so a grep for a stray raw `Icons.`
  // stays a reliable signal instead of turning up known noise.
  static const IconData devHarness = Iconsax.code_circle;
  static const IconData devTestSmall = Iconsax.coin;
  static const IconData devTestReal = Iconsax.dollar_circle;
}

/// Icon sizes. Four steps, so a screen picks a ROLE rather than a number —
/// the app previously shipped 13 distinct icon sizes between 12 and 48.
class AppIconSize {
  const AppIconSize._();

  /// Inline with body text: chips, metadata rows, button affixes.
  static const double sm = 16;

  /// The default. List rows, tiles, app-bar actions, navigation.
  static const double md = 20;

  /// Section headers and card leading marks.
  static const double lg = 24;

  /// Empty states and full-screen status art — the only size allowed to
  /// carry a screen on its own.
  static const double xl = 48;
}

/// The rounded, tinted square behind a leading icon.
///
/// This shape was copy-pasted across ~15 call sites at 40/42/44/48px with
/// radii of 10/12/13/14 and glyph sizes of 18/20/21/22 — close enough to
/// look accidental rather than designed, and drifting further with every new
/// screen. It is one component now.
///
/// COLOUR FOLLOWS THE RULE HELP24 ALREADY USED, rather than replacing it. A
/// plain navigational row is a brand-tinted box holding a NEUTRAL glyph; a
/// row that states a STATUS tints the box and the glyph together. So:
///
///   IconBadge(AppIcons.saved)                  → accent box, text-colour glyph
///   IconBadge(AppIcons.success, color: green)  → green box, green glyph
///   IconBadge(AppIcons.currentLocation,
///             color: AppTheme.primaryAccent)   → accent box, accent glyph
///
/// The third form is explicit on purpose: several screens deliberately draw
/// an accent-on-accent badge, and passing the colour says "I meant this"
/// instead of inheriting it by accident.
class IconBadge extends StatelessWidget {
  final IconData icon;

  /// Tints the backing, and the glyph too unless [foreground] overrides it.
  /// Defaults to the brand accent for the backing only.
  final Color? color;

  /// Escape hatch for the rare badge whose glyph must not follow its box.
  final Color? foreground;

  /// Outer square.
  final double size;

  /// Glyph size. Defaults to a proportion of [size] that holds the Iconsax
  /// optical weight steady as the badge scales.
  final double? iconSize;

  const IconBadge(
    this.icon, {
    super.key,
    this.color,
    this.foreground,
    this.iconSize,
  }) : size = 42;

  /// A compact badge for dense rows and bottom sheets.
  const IconBadge.small(
    this.icon, {
    super.key,
    this.color,
    this.foreground,
    this.iconSize,
  }) : size = 34;

  /// The prominent badge at the head of a sheet or an empty state.
  const IconBadge.large(
    this.icon, {
    super.key,
    this.color,
    this.foreground,
    this.iconSize,
  }) : size = 56;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tone = color ?? AppTheme.primaryAccent;
    final glyph = foreground ??
        color ??
        (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary);

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        // ~28% of the box rather than a fixed radius, so the corner keeps the
        // same optical roundness at 34, 42 and 56 instead of looking tight
        // when small and slack when large.
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(icon, color: glyph, size: iconSize ?? size * 0.48),
    );
  }
}
