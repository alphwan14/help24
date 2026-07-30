import 'dart:async';

import 'package:flutter/foundation.dart';

/// The launch, as ONE transaction.
///
/// THE PROBLEM THIS SOLVES
/// ----------------------
/// Help24 had no splash of its own. The Android launch theme paints until the
/// FIRST Flutter frame, and that frame was Discover — showing skeletons, with
/// the identity not yet resolved and the ranking not yet requested. Everything
/// that happened next therefore happened *in front of the user*:
///
///   * the disk cache hydrating (one install);
///   * the chronological page appearing because ranking was slow (another);
///   * the ranked page replacing it (another);
///   * `setViewer` arriving from HomeScreen's post-frame callback and, on a
///     lost race, discarding the splash-time ranking entirely and re-issuing it
///     (another).
///
/// Every install re-keys Discover's list, which crossfades the whole feed and
/// throws away the scroll position. Two installs is one visible blink; four is
/// the "it re-installs itself after it is already on screen" users reported.
///
/// None of the four is wrong on its own. The defect was that nothing owned the
/// question *"is the launch finished?"*, so nothing could answer *"may this be
/// shown to somebody yet?"*.
///
/// WHAT THIS IS
/// ------------
/// A single latch with a deadline. The splash is held until the launch feed is
/// FINAL; while it is held, installs are free — there is provably nothing on
/// screen to disturb, which is what [FeedArrival]'s `launchInProgress` rule
/// reads. When it lifts, Discover's first frame is the finished feed, and every
/// later arrival goes through the ordinary offer-don't-apply machinery.
///
/// FAILURE IS THE DESIGN CASE, NOT AN EDGE CASE
/// --------------------------------------------
/// [deadline] is a race, never a dependency: nothing here can prevent the app
/// from opening. A dead backend, a cold ranker, a denied permission or a widget
/// test that never builds a provider all lift the splash on time and land on
/// whatever the app does have — disk cache, chronological page, or the skeletons
/// that were the old behaviour. The worst case is exactly today; the common case
/// is a feed that was already waiting.
abstract final class LaunchSequence {
  /// How long the splash may hold before the app opens on whatever it has.
  ///
  /// Costs NOTHING on a healthy launch: the splash lifts the moment the feed is
  /// final, which for a warm ranked response is a few hundred milliseconds — so
  /// this bounds only the slow path, and raising it cannot make a fast launch
  /// slower.
  ///
  /// Raised from 2200ms after the first round of this work. The ranking backend
  /// sleeps when idle and mobile data here is not fast, so 2200ms was being
  /// exceeded routinely rather than exceptionally — and every time it was, the
  /// splash handed over on the chronological stand-in and the real ranking
  /// arrived a beat later, in front of the reader. Three seconds covers the
  /// backend warming up, which is the case that was actually failing.
  ///
  /// It is not the only defence, and it should not be treated as one: whatever
  /// arrives after the handover is now OFFERED rather than applied (see
  /// [FeedArrival]), so overrunning this costs a prompt, never a blink.
  static const Duration deadline = Duration(milliseconds: 3000);

  static Completer<void> _ready = Completer<void>();
  static Timer? _deadlineTimer;
  static bool _lifted = false;
  static DateTime? _startedAt;

  /// Milliseconds since [begin], for launch diagnostics. `-1` before it runs.
  ///
  /// Every launch log in the app is stamped with this rather than a wall clock:
  /// the only thing that matters when reading a launch trace is the ORDER and
  /// the gaps, and absolute timestamps make both harder to see.
  static int get sinceStart {
    final startedAt = _startedAt;
    return startedAt == null
        ? -1
        : DateTime.now().difference(startedAt).inMilliseconds;
  }

  /// Whether the splash is still up — i.e. whether an install is unseeable.
  ///
  /// Read synchronously by AppProvider on every arrival decision. False before
  /// [begin] runs (every widget test) so a test that never starts a launch
  /// behaves exactly like a running app that has finished one.
  static bool get isHoldingSplash => _deadlineTimer != null && !_lifted;

  /// Completes when the launch feed is final, or when [deadline] expires —
  /// whichever comes first. Never completes with an error.
  static Future<void> get ready => _ready.future;

  /// Whether the launch is ALREADY over.
  ///
  /// Read synchronously by the splash the moment it is constructed, because on
  /// a slow device the widget tree can take longer to exist than the entire
  /// launch takes to settle. Measured on a Galaxy A21s: the launch handed over
  /// at +3518ms and `StartupGate` was not created until +4280ms — so the gate
  /// woke up, found `_open` false, painted a splash for a launch that had
  /// finished three quarters of a second earlier, and faded it out again.
  ///
  /// That is the "it loads two separate splash screens" report, and it is why
  /// the launch looked different on different phones: on a fast device the gate
  /// exists within ~50ms and the splash is one continuous thing; on a slow one
  /// it arrives after the finish line. The Android window background has been
  /// showing the badge the whole time either way, so when this is true the right
  /// move is to hand straight to the app and never paint a Flutter splash at
  /// all.
  static bool get handedOver => _ready.isCompleted;

  /// Arm the deadline. Called from `main()` immediately after the prefetch is
  /// started, so the clock covers the whole launch including Firebase's session
  /// restore — not just the part after the widget tree exists.
  static void begin() {
    if (_deadlineTimer != null) return;
    _startedAt = DateTime.now();
    debugPrint('[LAUNCH] begin');
    _deadlineTimer = Timer(deadline, () => _settle('deadline'));
  }

  /// The launch feed is final: the splash may hand over.
  ///
  /// Idempotent and safe to call from every path that can produce a first feed
  /// — the ranked launch page, the degraded chronological one, the offline
  /// cache read, the viewer-grace backstop. Calling it more than once is free,
  /// which is deliberate: the alternative is one canonical call site that some
  /// future degradation path forgets, and a splash that hangs for the full
  /// deadline on exactly the launches that were already having a bad time.
  static void markFeedFinal() => _settle('feed ready');

  /// Called by the splash the frame it hands over. After this, arrivals are no
  /// longer free — they answer to [FeedArrival] like anything else.
  static void lift() {
    _lifted = true;
    debugPrint('[LAUNCH] +${sinceStart}ms lifted — arrivals are no longer free');
  }

  static void _settle(String reason) {
    if (_ready.isCompleted) return;
    debugPrint('[LAUNCH] +${sinceStart}ms handing over ($reason)');
    _ready.complete();
  }

  /// Test seam: forget the latch so an isolated test starts from a cold app.
  @visibleForTesting
  static void resetForTest() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _lifted = false;
    _ready = Completer<void>();
  }

  /// Test seam: run [body] as though the splash were still up.
  @visibleForTesting
  static void debugHoldSplash(void Function() body) {
    final wasLifted = _lifted;
    final hadTimer = _deadlineTimer;
    _lifted = false;
    _deadlineTimer ??= Timer(deadline, () {});
    try {
      body();
    } finally {
      _lifted = wasLifted;
      if (hadTimer == null) {
        _deadlineTimer?.cancel();
        _deadlineTimer = null;
      }
    }
  }
}
