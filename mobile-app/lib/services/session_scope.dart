import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_local_prefs.dart';

/// The missing concept: a SESSION, not just a token.
///
/// WHY THIS EXISTS
/// ---------------
/// Sign-out used to be an *auth* operation — clear the Firebase user, drop the
/// Supabase JWT — while every cache the app had accumulated decided for itself
/// whether to care. None of them did. The result was reproducible and serious:
/// account A's conversation list, read from a device-global SharedPreferences
/// key, rendered inside account C's session (see `CacheService`, which now
/// scopes every user-owned key by uid).
///
/// The defect was never one bad cache. It was that nothing owned the moment a
/// session ends, so each new feature silently opted out of cleanup. This class
/// is that owner:
///
///   * user-scoped stores REGISTER here and are reset together, or
///   * user-scoped SharedPreferences keys are namespaced with [scopedKey] and
///     purged wholesale by prefix.
///
/// TWO INDEPENDENT DEFENCES, DELIBERATELY
/// --------------------------------------
/// Namespacing makes a cross-account read *impossible* (a key for uid A is not
/// a key any uid-C read will ever construct). Purging makes stale data
/// *absent*. Either alone would have prevented the leak; both together mean a
/// future cache that forgets one is still covered by the other.
abstract class SessionScoped {
  /// Drop every piece of state derived from the signed-in user. Must not throw
  /// and must not await network work — sign-out can never be blocked by
  /// cleanup, or a failed cleanup traps the user in a signed-in state.
  void resetForSignOut();
}

class SessionScope {
  SessionScope._();
  static final SessionScope instance = SessionScope._();

  final List<SessionScoped> _members = [];

  /// Keys shaped `<prefix><uid>` or `<prefix><uid>_<suffix>`. The uid is part
  /// of the key, so ownership is decidable and only the owner's keys are
  /// removed.
  ///
  /// Public marketplace data (`help24_cache_posts`, `help24_cache_jobs`) is
  /// deliberately absent: it is the same for every account, so scoping it would
  /// cost a cold feed on every switch and protect nothing.
  static const List<String> uidScopedPrefixes = [
    'help24_cache_conversations_',
    'help24_cache_messages_',
    'help24_outbox_',
  ];

  /// Keys that belong to the signed-in user but carry NO uid — device-local
  /// chat preferences keyed by chat id, and the notification thread cache.
  ///
  /// They are not namespaced because the FCM background isolate reads them and
  /// has no session to namespace against. Ownership is therefore undecidable
  /// from the key, so they are destroyed wholesale when a session ends.
  ///
  /// Critically, these are NOT swept at startup: doing so would delete the
  /// current user's mutes on every launch. They are removed only at a real
  /// session boundary — sign-out, or a detected account change.
  static const List<String> _sessionWidePrefixes = [
    'help24_muted_chats',
    'help24_chat_cleared_',
    'help24_chat_hidden_',
    'help24_cn_',
  ];

  /// Legacy device-global keys from before scoping existed. Unattributable, so
  /// deleted on sight and never written again.
  ///
  /// Legacy `help24_cache_messages_<chatId>` / `help24_outbox_<chatId>` keys
  /// need no entry here: they share a prefix with the scoped form, and their
  /// "owner" segment parses to a chat id, which never equals a signed-in uid —
  /// so the ownership test always condemns them.
  static const List<String> _legacyUnscopedKeys = [
    'help24_cache_conversations',
  ];

  /// Records which uid the on-device session-wide state currently belongs to.
  ///
  /// Without this, a process killed mid-session loses the knowledge of who was
  /// signed in, and a different account signing in next launch would inherit
  /// the un-namespaced chat preferences. Persisting the owner lets startup
  /// detect that change and clean up as if a sign-out had happened.
  static const String _sessionOwnerKey = 'help24_session_owner';

  void register(SessionScoped member) {
    if (!_members.contains(member)) _members.add(member);
  }

  void unregister(SessionScoped member) => _members.remove(member);

  /// Build a uid-namespaced key. A read for the wrong user cannot collide with
  /// a write from another — the uid is part of the key, not a filter applied
  /// after the data is already in hand.
  static String scopedKey(String prefix, String uid, [String? suffix]) =>
      suffix == null ? '$prefix$uid' : '$prefix${uid}_$suffix';

  /// End the session. Synchronous provider reset first (so no frame can paint
  /// the previous user's data), then a best-effort disk purge.
  ///
  /// Call BEFORE the identity provider signs out, while [uid] is still known.
  Future<void> endSession(String? uid) async {
    for (final member in _members) {
      try {
        member.resetForSignOut();
      } catch (e) {
        // One misbehaving store must not prevent the others from resetting.
        debugPrint('[SESSION] reset failed for ${member.runtimeType}: $e');
      }
    }
    // Static in-memory mirrors that no provider owns. These outlive the widget
    // tree, so purging their keys without clearing them would leave the next
    // account reading the previous one's answers.
    ChatLocalPrefs.resetForSignOut();
    await _purgeKeys(ownedBy: uid, includeSessionWide: true);
  }

  /// Startup hygiene, before any screen can read a cache.
  ///
  /// Removes uid-scoped data belonging to anyone other than [currentUid], plus
  /// the pre-scoping global keys — this is what retires data already sitting on
  /// devices that ran the leaking build.
  ///
  /// Session-wide (un-namespaced) keys are removed ONLY when the recorded
  /// session owner differs from [currentUid], i.e. the previous session ended
  /// without a clean sign-out and a different account is now signed in. On a
  /// normal relaunch by the same user they are left alone, so mutes survive.
  Future<void> purgeForeignScopes(String? currentUid) async {
    final ownerChanged = await _claimSessionOwner(currentUid);
    await _purgeKeys(
      exceptOwnedBy: currentUid,
      includeSessionWide: ownerChanged,
    );
    if (ownerChanged) ChatLocalPrefs.resetForSignOut();
  }

  /// Records [currentUid] as the owner of the device's session-wide state.
  /// Returns true when that differs from the previously recorded owner.
  Future<bool> _claimSessionOwner(String? currentUid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getString(_sessionOwnerKey);
      final current = currentUid ?? '';
      if (previous == current) return false;
      // A first-ever launch (no record) is not an account change.
      final changed = previous != null && previous != current;
      if (current.isEmpty) {
        await prefs.remove(_sessionOwnerKey);
      } else {
        await prefs.setString(_sessionOwnerKey, current);
      }
      if (changed) {
        debugPrint('[SESSION] device owner changed since last launch');
      }
      return changed;
    } catch (e) {
      debugPrint('[SESSION] owner check failed: $e');
      // Unknown ownership → assume it changed. Over-cleaning costs a mute
      // setting; under-cleaning costs another account's data on screen.
      return true;
    }
  }

  /// Removes user-owned keys.
  ///
  /// * [ownedBy] — remove uid-scoped keys for exactly this uid (session end).
  /// * [exceptOwnedBy] — remove uid-scoped keys for every OTHER uid (startup).
  /// * [includeSessionWide] — also remove the un-namespaced keys.
  ///
  /// Legacy unscoped keys are removed in every mode: they have no owner, so
  /// they can never be proven safe to keep.
  Future<void> _purgeKeys({
    String? ownedBy,
    String? exceptOwnedBy,
    bool includeSessionWide = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Another isolate (the FCM background handler) writes some of these.
      await prefs.reload();

      final doomed = <String>{};

      for (final key in prefs.getKeys()) {
        if (_legacyUnscopedKeys.contains(key)) {
          doomed.add(key);
          continue;
        }

        if (includeSessionWide &&
            _sessionWidePrefixes.any(key.startsWith)) {
          doomed.add(key);
          continue;
        }

        // A legacy `help24_cache_messages_<chatId>` has no uid segment and is
        // indistinguishable from a scoped key by prefix alone. Both are covered
        // by the ownership test: an unscoped key's "owner" parses to a chat id,
        // which never equals a signed-in uid, so it is always condemned.
        final prefix = uidScopedPrefixes
            .where((p) => key.startsWith(p))
            .fold<String?>(null, (longest, p) =>
                longest == null || p.length > longest.length ? p : longest);
        if (prefix == null) continue;

        final owner = _ownerOf(key, prefix);
        // An empty owner means the key carries no uid at all — unattributable,
        // therefore never safe to keep.
        if (owner.isEmpty) {
          doomed.add(key);
        } else if (ownedBy != null && owner == ownedBy) {
          doomed.add(key);
        } else if (exceptOwnedBy != null && owner != exceptOwnedBy) {
          doomed.add(key);
        } else if (ownedBy == null && exceptOwnedBy == null) {
          // Signed out with no uid to attribute: purge everything user-scoped.
          doomed.add(key);
        }
      }

      for (final key in doomed) {
        await prefs.remove(key);
      }
      if (doomed.isNotEmpty) {
        debugPrint('[SESSION] purged ${doomed.length} user-scoped key(s)');
      }
    } catch (e) {
      debugPrint('[SESSION] key purge failed: $e');
    }
  }

  /// The uid segment of a scoped key. Keys shaped `<prefix><uid>` yield the uid
  /// directly; `<prefix><uid>_<suffix>` yields the part before the first `_`.
  /// Exact-match preference keys (no uid at all) report an empty owner, which
  /// matches no signed-in uid and is therefore always purged.
  static String _ownerOf(String key, String prefix) {
    if (key.length == prefix.length) return '';
    final rest = key.substring(prefix.length);
    final split = rest.indexOf('_');
    return split == -1 ? rest : rest.substring(0, split);
  }
}

/// Prefixes used to build scoped keys. Kept beside the purge list so a new
/// cache cannot add one without the purge seeing it.
class SessionKeys {
  SessionKeys._();

  static const String conversations = 'help24_cache_conversations_';
  static const String messages = 'help24_cache_messages_';
  static const String outbox = 'help24_outbox_';
}
