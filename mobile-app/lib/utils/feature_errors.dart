/// Per-feature error state — one slot each, never shared.
///
/// WHY THIS FILE EXISTS
/// --------------------
/// `AppProvider` held ONE `String? _error` that five unrelated features wrote
/// to and four read from: the Discover feed, the Jobs tab, post/job creation,
/// post deletion and chat creation. A single slot with many owners produces two
/// failure modes, and Help24 had both:
///
///   * CONTAMINATION — `createPost` fails and sets the slot; Discover's feed
///     happens to be empty (new account, or filters that match nothing), so the
///     feed renders `ErrorRetryView` with a POSTING message ("Could not save.
///     Please try again.") above a Retry button that reloads the feed. Wrong
///     feature, wrong message, wrong remedy.
///
///   * ERASURE — every loader clears the slot as it starts. `loadPosts` and
///     `loadJobs` run concurrently under one `Future.wait`, so whichever starts
///     second wipes the other's freshly-set error before anything renders it.
///     Worse, a feed reload triggered anywhere would destroy the message from a
///     failed post creation microseconds before `PostScreen` read it — which is
///     why a failed post could surface as the generic fallback string instead
///     of the real reason.
///
/// One owner per slot removes both by construction: a feature can only clear
/// what it set, and can only read what it owns.
///
/// Pure Dart — no Flutter, no network — so the isolation is unit-testable.
library;

/// A surface that can fail independently of every other surface.
///
/// Only features whose error state lives in `AppProvider` appear here.
/// Notifications, Profile, Applications, Saved and the job-lifecycle screens
/// already hold their own local `_error` and were never part of the shared slot;
/// adding them would centralise state that is correctly local.
enum AppFeature {
  /// The Discover feed (`loadPosts`).
  discover,

  /// The Jobs tab (`loadJobs`).
  jobs,

  /// Urgent requests (`loadUrgentPosts`) — its own surface with its own Retry.
  urgent,

  /// The conversation list (`loadConversations`).
  messages,

  /// Creating and archiving listings (`createPost`, `createJob`, `deletePost`).
  posting,
}

/// A set of independent error slots, one per [AppFeature].
///
/// Deliberately a map behind an enum rather than N loose `String?` fields: it
/// makes "every feature has exactly one slot, and nothing can write another
/// feature's" a property of the type instead of a convention. Adding a feature
/// is one enum case, and it starts isolated.
class FeatureErrors {
  final Map<AppFeature, String> _messages = {};

  /// The current error for [feature], or null when it is healthy.
  String? operator [](AppFeature feature) => _messages[feature];

  /// True when [feature] currently has an error.
  bool has(AppFeature feature) => _messages.containsKey(feature);

  /// Record (or clear, with null) [feature]'s error.
  ///
  /// Returns whether anything actually changed, so a caller can avoid a
  /// pointless rebuild — clearing an already-clear slot at the start of every
  /// load is the common case.
  bool set(AppFeature feature, String? message) {
    final next = (message == null || message.isEmpty) ? null : message;
    final previous = _messages[feature];
    if (previous == next) return false;
    if (next == null) {
      _messages.remove(feature);
    } else {
      _messages[feature] = next;
    }
    return true;
  }

  /// Clear [feature]'s slot. Returns whether it had one.
  bool clear(AppFeature feature) => set(feature, null);

  /// Drop every slot — used on sign-out, where all of it belonged to the
  /// outgoing session.
  bool clearAll() {
    if (_messages.isEmpty) return false;
    _messages.clear();
    return true;
  }

  /// True when no feature is in an error state.
  bool get isEmpty => _messages.isEmpty;

  /// Features currently in an error state. Diagnostics only — no UI branches on
  /// this, because a screen must render ITS failure, never "something failed".
  Iterable<AppFeature> get failing => _messages.keys;
}
