import '../models/post_model.dart';

/// The urgent window — how long an emergency request stays an emergency.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// "Urgent" is a claim with an expiry date. `PostService.fetchUrgentPosts`
/// enforces it server-side (`urgent_expires_at > now()`), but the result is then
/// held in memory: a request whose hour ran out while someone had the screen
/// open stayed on the list, still labelled URGENT, still inviting a response to
/// something that is no longer urgent.
///
/// Expiry is a property of the post and the clock, not of when a query last ran.
/// Stating it here — pure, no Flutter — lets the UI apply it on every frame and
/// lets it be tested against a fixed clock instead of a real one.

/// Time left in [post]'s urgent window at [now], or null when the post carries
/// no window (never urgent, or a legacy row with no expiry).
///
/// Returns `Duration.zero` for a window that has already closed, so callers can
/// treat "expired" and "expiring" with the same comparison.
Duration? urgentTimeRemaining(PostModel post, DateTime now) {
  final expiresAt = post.urgentExpiresAt;
  if (expiresAt == null) return null;
  final left = expiresAt.toUtc().difference(now.toUtc());
  return left.isNegative ? Duration.zero : left;
}

/// Whether [post] should still appear on an urgency surface at [now].
///
/// A post with no expiry is NOT filtered out: legacy urgent rows predate the
/// window, and silently hiding them would make real requests disappear. Only a
/// window that demonstrably closed removes a post.
bool isUrgentWindowOpen(PostModel post, DateTime now) {
  final expiresAt = post.urgentExpiresAt;
  if (expiresAt == null) return true;
  return expiresAt.toUtc().isAfter(now.toUtc());
}

/// The live urgency list: server results minus anything whose window closed
/// while the list sat on screen. Order is preserved — proximity sorting already
/// happened upstream.
List<PostModel> openUrgentPosts(List<PostModel> posts, DateTime now) =>
    posts.where((p) => isUrgentWindowOpen(p, now)).toList();

/// Countdown label for an urgent card: "3h 57m left", "42 min left", "40s left".
///
/// Units track what the reader can act on, which is the whole point of showing
/// a countdown rather than a static "Urgent" tag. Seconds below a minute,
/// minutes below an hour, hours and minutes above it.
///
/// THE HOURS BRANCH EXISTS BECAUSE OF A REAL POST. An urgent request with a
/// four-hour window rendered as "237 min left" on the S20+ — a number nobody
/// converts in their head, from a function whose own contract says it must
/// "never [show] a number that implies more precision than the reader can act
/// on". 237 minutes is precision without meaning.
///
/// Null when there is no window to count down — the card then shows its
/// ordinary urgency tag instead.
String? formatUrgentCountdown(Duration? remaining) {
  if (remaining == null) return null;
  if (remaining <= Duration.zero) return 'Expired';
  if (remaining.inHours >= 1) {
    final minutes = remaining.inMinutes % 60;
    // A whole number of hours says so rather than trailing a redundant "0m".
    return minutes == 0
        ? '${remaining.inHours}h left'
        : '${remaining.inHours}h ${minutes}m left';
  }
  if (remaining.inMinutes >= 1) return '${remaining.inMinutes} min left';
  return '${remaining.inSeconds}s left';
}

/// Convenience: the countdown label for [post] at [now].
String? urgentCountdownFor(PostModel post, DateTime now) =>
    formatUrgentCountdown(urgentTimeRemaining(post, now));
