import '../models/post_model.dart';

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
