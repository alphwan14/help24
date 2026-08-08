import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/filter_selection.dart';

/// THE FILTERS THIS ACCOUNT HAS ACTUALLY USED.
///
/// Filters were entirely in-memory: every one a user built died with the
/// process, so the same search had to be reassembled chip by chip on every
/// launch. This remembers them.
///
/// Three rules make it safe rather than merely convenient:
///
///  * **Per account, by key.** Entries live under `filter_history_v1_<uid>`.
///    Isolation is structural — signing in as someone else reads a different
///    key, so there is no window in which one account can render another's
///    history even if a clear were missed. (`clearForSignOut` still runs, so
///    the outgoing account's filters do not sit in memory behind the next
///    person's session.)
///  * **Distinct sets only.** Deduplicated on [FilterSelection.signature],
///    which is order-independent and case-folded, so re-applying yesterday's
///    filter moves it to the front instead of stacking a near-identical twin.
///  * **Nothing is executed by remembering it.** Recording happens on apply and
///    reading happens on open; opening the sheet never runs a stored filter.
///
/// Reads are tolerant: history is a convenience, and a single unparseable entry
/// written by an older build must never cost the user the rest of the list, let
/// alone throw on a screen open.
class FilterHistoryService {
  FilterHistoryService._();
  static final FilterHistoryService instance = FilterHistoryService._();

  /// Visible for tests: the exact key an account's history lives under.
  static String keyFor(String userId) => 'filter_history_v1_${userId.trim()}';

  /// Deliberately small. This is "the searches you keep coming back to", not a
  /// log — a list long enough to scroll is a list nobody reads.
  static const int maxEntries = 8;

  String _userId = '';
  List<FilterSelection> _entries = const [];
  bool _loaded = false;

  /// Newest first. Empty until [load] has run for an account, and empty for a
  /// signed-out session — never another account's list.
  List<FilterSelection> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  /// Read this account's history from disk. Idempotent per account; switching
  /// accounts re-reads under the new key.
  ///
  /// Never throws: a failure leaves the list empty, which renders as "no recent
  /// filters" — the honest answer when we could not read them.
  Future<void> load(String userId) async {
    final uid = userId.trim();
    if (_loaded && _userId == uid) return;
    _userId = uid;
    _entries = const [];
    _loaded = true;
    if (uid.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyFor(uid));
      if (raw == null || raw.isEmpty) return;
      // Re-checked across the await: a sign-out or account switch may have
      // overtaken the disk read, and disk data must never win against it.
      if (_userId != uid) return;
      _entries = decode(raw);
    } catch (e) {
      debugPrint('[FILTER_HISTORY] read failed: $e');
    }
  }

  /// Record [selection] as the most recently used filter set.
  ///
  /// An empty selection is not a filter — "show me everything" is the absence
  /// of one, and saving it would put a meaningless row at the top of the list.
  Future<void> record(FilterSelection selection) async {
    if (_userId.isEmpty || selection.isEmpty) return;
    final signature = selection.signature;
    final next = <FilterSelection>[
      selection,
      for (final e in _entries)
        if (e.signature != signature) e,
    ];
    if (next.length > maxEntries) next.removeRange(maxEntries, next.length);
    _entries = next;
    await _persist();
  }

  /// Forget everything this account has searched for.
  Future<void> clear() async {
    if (_entries.isEmpty && _userId.isEmpty) return;
    _entries = const [];
    if (_userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyFor(_userId));
    } catch (e) {
      debugPrint('[FILTER_HISTORY] clear failed: $e');
    }
  }

  /// Drop the in-memory list on sign-out WITHOUT erasing it from disk.
  ///
  /// Synchronous by contract, like the rest of the sign-out teardown: it runs
  /// before the identity provider signs out, so no frame can paint the previous
  /// account's filters during the transition. The stored copy survives because
  /// it is keyed by that account's uid — signing back in restores your own
  /// filters, and a different account simply reads a different key and finds
  /// nothing.
  void clearForSignOut() {
    _entries = const [];
    _userId = '';
    _loaded = false;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyFor(_userId), encode(_entries));
    } catch (e) {
      debugPrint('[FILTER_HISTORY] write failed: $e');
    }
  }

  // ── Pure codec, exposed for tests ─────────────────────────────────────────

  static String encode(List<FilterSelection> entries) =>
      jsonEncode([for (final e in entries) e.toJson()]);

  /// Tolerant decode: skips anything unreadable, drops duplicates that a
  /// previous build may have written, and enforces the cap on read as well as
  /// on write so a corrupt file cannot grow the list unbounded.
  static List<FilterSelection> decode(String raw) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! List) return const [];
      final seen = <String>{};
      final out = <FilterSelection>[];
      for (final item in parsed) {
        final selection = FilterSelection.tryParse(item);
        if (selection == null) continue;
        if (!seen.add(selection.signature)) continue;
        out.add(selection);
        if (out.length >= maxEntries) break;
      }
      return out;
    } catch (e) {
      debugPrint('[FILTER_HISTORY] decode failed: $e');
      return const [];
    }
  }
}
