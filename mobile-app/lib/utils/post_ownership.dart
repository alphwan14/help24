import '../models/post_model.dart';
import 'post_intent.dart';

/// Ownership and response rules for a marketplace listing — the SINGLE
/// definition every surface reads.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// The same job post used to produce three different experiences depending on
/// which screen it was opened from:
///
///   * `PostCard` decided ownership and swapped in an owner button.
///   * `PostDetailScreen` decided ownership again inline, but gated every
///     owner affordance on `type == PostType.request` — so the author of a JOB
///     post got a dead-end sentence ("You posted this job") instead of their
///     applicants.
///   * `JobCard` computed ownership and then used it only to pick a display
///     name, leaving an "Apply" button on the viewer's own post.
///   * `ApplicationService` never checked ownership at all, so that button
///     reached the database, where a trigger rejected the insert and the user
///     read the generic "We couldn't send your response."
///
/// Four copies of one rule, disagreeing. These predicates replace all of them.
/// Pure Dart — no Flutter, no network — so every surface reads the same answer
/// and the rules are unit-testable on their own.

/// True when [viewerUserId] authored the listing.
///
/// Empty ids never match. A legacy row can carry an empty `author_user_id` and
/// a signed-out viewer has an empty id; treating `'' == ''` as ownership would
/// hand a stranger the owner's management screen.
bool isListingOwner({String? authorUserId, String? viewerUserId}) {
  final author = authorUserId ?? '';
  final viewer = viewerUserId ?? '';
  return author.isNotEmpty && viewer.isNotEmpty && author == viewer;
}

/// Whether people respond to this listing by APPLYING — writing a row in
/// `applications` — rather than by starting a private conversation.
///
/// Requests and job posts both take applications; offers are a provider
/// advertising a service, which people enquire about in chat.
///
/// This — not `type == PostType.request` — is the correct gate for every
/// applicant-facing affordance. Gating on `request` is precisely what left job
/// owners with no route to their applicants.
bool listingTakesApplications(PostType type) => type != PostType.offer;

/// Whether a listing still accepts responses. Offers are standing adverts and
/// have no lifecycle; requests and jobs stop accepting once they leave 'open'.
bool listingIsOpen({required PostType type, required String status}) {
  if (type == PostType.offer) return true;
  return status.isEmpty || status == 'open';
}

/// The kind the AUTHOR may switch their listing to, or null when they may not.
///
/// People pick the wrong kind ("Edger here anyone in need of plumber" went up
/// as a request), so the author can swap a request and an offer while nothing
/// depends on the old kind yet: the listing is open, nobody has been chosen,
/// and nobody has responded. A job has its own form, so it never switches.
///
/// This only decides whether to OFFER the control. The database decides
/// whether the change happens (migration 145, `trg_posts_type_change`), and an
/// admin can still reclassify anything open from the console.
PostType? ownerTypeSwitchTarget({
  required PostType type,
  required String status,
  String? selectedProviderId,
  required int applicationCount,
}) {
  if (status.isNotEmpty && status != 'open') return null;
  if ((selectedProviderId ?? '').isNotEmpty) return null;
  if (applicationCount > 0) return null;
  return switch (type) {
    PostType.request => PostType.offer,
    PostType.offer => PostType.request,
    PostType.job => null,
  };
}

/// The correction to OFFER the author of a posted listing, or null.
///
/// A correction, not a free choice. The switch used to appear on every open
/// request and offer, so an author could turn "Am an experienced welder based
/// in Mombasa" into a request (the owner did, to see what happens): the label
/// then contradicted the words, the exact problem the switch exists to fix.
/// Now it appears only when BOTH hold:
///   * the listing may still change kind ([ownerTypeSwitchTarget]), and
///   * its own words read as that other kind (the composer's nudge check,
///     [suggestedPostType], with the same phrase lists).
/// So a mislabelled post ("Edger here anyone in need of plumber" as a
/// request) is offered "Change to an offer"; a correctly labelled or neutral
/// one is offered nothing. An admin can still reclassify any open listing
/// from the console, with a reason.
PostType? ownerTypeCorrection({
  required PostType type,
  required String status,
  String? selectedProviderId,
  required int applicationCount,
  required String title,
  String description = '',
}) {
  final to = ownerTypeSwitchTarget(
    type: type,
    status: status,
    selectedProviderId: selectedProviderId,
    applicationCount: applicationCount,
  );
  if (to == null) return null;
  final words = suggestedPostType(chosen: type, title: title, description: description);
  return words == to ? to : null;
}

/// The primary action a listing should offer the person looking at it.
enum ListingCta {
  /// Viewer owns the listing — open the management experience. Never an Apply.
  manage,

  /// Viewer may apply (request or job post that is still open).
  apply,

  /// Viewer already responded — reflect it instead of re-inviting a duplicate.
  applied,

  /// Offer post: start a private conversation with the provider.
  enquire,

  /// Request/job that is assigned, completed, disputed or cancelled.
  unavailable,
}

/// The one CTA decision, shared by the feed cards and the detail action bar.
///
/// Ownership is checked FIRST and unconditionally: whatever else is true of a
/// listing, its author is never invited to respond to it.
ListingCta listingCtaFor({
  required PostType type,
  required String authorUserId,
  required String viewerUserId,
  required String status,
  required bool hasApplied,
}) {
  if (isListingOwner(authorUserId: authorUserId, viewerUserId: viewerUserId)) {
    return ListingCta.manage;
  }
  if (!listingIsOpen(type: type, status: status)) return ListingCta.unavailable;
  if (hasApplied) return ListingCta.applied;
  return type == PostType.offer ? ListingCta.enquire : ListingCta.apply;
}

/// The noun used when talking to the author about their own listing, e.g.
/// "You posted this service".
String listingNoun(PostType type) => switch (type) {
      PostType.request => 'request',
      PostType.offer => 'service',
      PostType.job => 'job',
    };

/// What became of an application the VIEWER sent.
///
/// The counterpart to [ListingCta]: that answers "what may I do with this
/// listing", this answers "what happened to the response I already sent".
///
/// Derived entirely from the LISTING (`status` + `selected_provider_id`),
/// because the `applications` row carries no outcome of its own — it records
/// that you applied, when, and for how much, and nothing about the decision.
/// Deriving it here rather than adding a column keeps one source of truth: the
/// post's lifecycle already decides this, and a second copy could disagree
/// with the screen the owner is looking at.
enum ApplicationOutcome {
  /// Still open, nobody chosen. The only state the applicant can still win.
  pending,

  /// The viewer was chosen and the work is under way.
  hired,

  /// The viewer was chosen and the work is finished.
  completed,

  /// The viewer was chosen and the job is in dispute.
  disputed,

  /// Someone else was chosen. Said plainly, once — see the note below.
  notSelected,

  /// The listing left 'open' without naming this viewer: cancelled, or an
  /// assignment we cannot attribute. Never reported as a rejection, because we
  /// do not know that it was one.
  closed,
}

/// The one derivation, shared by the applied list and anything added later.
///
/// [selectedProviderUserId] is the post's chosen provider (null while open).
/// Empty ids never match, for the same reason they never match in
/// [isListingOwner]: a legacy row with an empty `selected_provider_id` must not
/// read as "you were hired" to a signed-out viewer.
ApplicationOutcome applicationOutcomeFor({
  required String status,
  required String? selectedProviderUserId,
  required String viewerUserId,
}) {
  final selected = selectedProviderUserId ?? '';
  final viewer = viewerUserId;
  final chosenIsViewer =
      selected.isNotEmpty && viewer.isNotEmpty && selected == viewer;

  if (chosenIsViewer) {
    return switch (status) {
      'completed' => ApplicationOutcome.completed,
      'disputed' => ApplicationOutcome.disputed,
      _ => ApplicationOutcome.hired,
    };
  }

  // Still taking responses — and nobody has been chosen, or we cannot tell.
  if (status.isEmpty || status == 'open') return ApplicationOutcome.pending;

  // Someone else was named. This is the only case we are entitled to call a
  // rejection, and only because the post itself names a different provider.
  if (selected.isNotEmpty) return ApplicationOutcome.notSelected;

  return ApplicationOutcome.closed;
}

/// Short label for an outcome. Kept beside the derivation so a new state can
/// never ship without one.
String applicationOutcomeLabel(ApplicationOutcome outcome) => switch (outcome) {
      ApplicationOutcome.pending => 'Awaiting decision',
      ApplicationOutcome.hired => 'You were hired',
      ApplicationOutcome.completed => 'Completed',
      ApplicationOutcome.disputed => 'In dispute',
      ApplicationOutcome.notSelected => 'Not selected',
      ApplicationOutcome.closed => 'Closed',
    };

/// Whether an outcome is still live work the applicant should act on.
///
/// Drives ordering on the applied list: a decision you can still influence, or
/// a job you are actually doing, outranks a closed one however recent.
bool applicationOutcomeIsLive(ApplicationOutcome outcome) => switch (outcome) {
      ApplicationOutcome.pending ||
      ApplicationOutcome.hired ||
      ApplicationOutcome.disputed =>
        true,
      ApplicationOutcome.completed ||
      ApplicationOutcome.notSelected ||
      ApplicationOutcome.closed =>
        false,
    };
