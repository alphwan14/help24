import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_scope.dart';

/// Which urgent requests this person has already looked at.
///
/// ── The problem this fixes ──────────────────────────────────────────────
/// Discover's `Urgent · N` counted every emergency whose window was still
/// open. That is an INVENTORY, and it is a perfectly good fact — an open
/// emergency is still open whether or not you have seen it. But it was drawn
/// as a red count, and a red count means one thing to everyone who has ever
/// used a phone: *N things you have not dealt with yet*.
///
/// So the number never moved. Open the list, read the request, come back —
/// still `Urgent · 1`. A badge that does not respond to being looked at
/// teaches people to stop looking, which is the one outcome an emergency
/// surface cannot afford. Reported from the device, and correctly.
///
/// ── What the number means now ───────────────────────────────────────────
/// **Unseen open emergencies.** The entry point itself never disappears —
/// `Urgent` stays in the header whether there is something new or not, because
/// the screen behind it is still worth reaching. What decays is the COUNT,
/// which is the part that was making a promise it could not keep.
///
/// ── Seen means "the list was on screen" ─────────────────────────────────
/// Not "you opened the post". A provider who reads the list and decides none
/// of them are theirs has seen them, and badging them again would be the same
/// failure one step later.
///
/// ── Bounded ─────────────────────────────────────────────────────────────
/// The set is pruned against the live open set every time it is consulted, so
/// it holds at most the currently-open emergencies rather than growing for the
/// life of the install. Urgent windows are hours long; this stays tiny.
class UrgentSeenStore extends ChangeNotifier implements SessionScoped {
  UrgentSeenStore._() {
    SessionScope.instance.register(this);
  }

  static final UrgentSeenStore instance = UrgentSeenStore._();

  /// Device-local and NOT user-scoped by key, because it is registered with
  /// [SessionScope] and cleared on sign-out instead. Nothing here identifies a
  /// person — it is a list of public post ids — so the purge is sufficient.
  static const _key = 'help24_urgent_seen';

  Set<String> _seen = <String>{};
  bool _loaded = false;

  /// Read the persisted set once. Safe to call repeatedly.
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _seen = (prefs.getStringList(_key) ?? const <String>[]).toSet();
    } catch (e) {
      // A cache that cannot be read is an empty cache, never a crash on the
      // path to an emergency list.
      debugPrint('[URGENT_SEEN] load failed: $e');
      _seen = <String>{};
    }
    _loaded = true;
    notifyListeners();
  }

  /// How many of [openIds] have not been seen yet.
  ///
  /// Takes the OPEN ids rather than reading state of its own, so the count can
  /// never disagree with the list the user is about to open.
  int unseenCount(Iterable<String> openIds) =>
      openIds.where((id) => !_seen.contains(id)).length;

  bool hasSeen(String id) => _seen.contains(id);

  /// Record that every one of [openIds] has now been presented, and forget any
  /// id that is no longer open.
  Future<void> markSeen(Iterable<String> openIds) async {
    final open = openIds.toSet();
    // Prune first: an id whose window closed can never be counted again, so
    // keeping it would only grow the set.
    final next = <String>{..._seen.where(open.contains), ...open};
    if (setEquals(next, _seen)) return;
    _seen = next;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, _seen.toList());
    } catch (e) {
      // The in-memory set is already correct; losing the write costs one
      // re-badge after a restart, which is the gentler failure.
      debugPrint('[URGENT_SEEN] persist failed: $e');
    }
  }

  @override
  void resetForSignOut() {
    if (_seen.isEmpty) return;
    _seen = <String>{};
    notifyListeners();
    // Fire-and-forget by contract: sign-out must never await cleanup.
    SharedPreferences.getInstance()
        .then((p) => p.remove(_key))
        .catchError((Object e) {
      debugPrint('[URGENT_SEEN] clear failed: $e');
      return false;
    });
  }

  @visibleForTesting
  void debugReset() {
    _seen = <String>{};
    _loaded = false;
  }

  @visibleForTesting
  Set<String> get debugSeen => Set.unmodifiable(_seen);
}
