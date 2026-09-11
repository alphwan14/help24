/// What the notifications switch shows, and when it is allowed to move.
///
/// WHY THIS EXISTS
/// ---------------
/// One tap on the Notifications switch produced THREE visible states. Traced on
/// an SM-G986U (Android 13), turning it off:
///
/// ```text
/// 31.555  onChanged(false)                              SWITCH=false   ← tap
/// 31.567  watchUserPrefs() created a NEW stream         (rebuild spawned a poll)
/// 32.037  db read  -> enabled=true                      (read issued BEFORE the write landed)
/// 32.038  db write -> enabled=false done
/// 32.438  optimistic value cleared
/// 32.448  paint streamValue=true                        SWITCH=true    ← FLASH BACK ON
/// 32.847  db read  -> enabled=false
/// 32.863  paint streamValue=false                       SWITCH=false   ← settles
/// ```
///
/// Two mistakes combined. The preference stream was rebuilt inside `build()`,
/// so the rebuild caused by the tap itself fired a fresh read that overlapped
/// the write; and when the write finished, the user's choice was discarded
/// unconditionally, handing the display to whatever that read had returned —
/// the value from BEFORE the write.
///
/// THE RULES ENCODED HERE
///   1. A choice the user has made outranks the stored value until its own
///      write resolves. It is not "optimism" to be dropped on completion: it is
///      the newest thing anyone knows.
///   2. A write that SUCCEEDED is the newest fact of all. What we wrote becomes
///      the stored value, because no read can describe anything newer.
///   3. A write that FAILED never happened. The switch returns to the stored
///      value rather than claiming a preference that was not saved.
///   4. A read updates what is stored but never overrules a choice that is
///      still being written — including a second tap made while the first write
///      is in flight, which is why retiring a pending value checks that it is
///      the value we actually wrote.
///
/// Companion rule, enforced one layer down in `UserProfileService`: a read that
/// was in flight when a write landed is stale and is dropped, never published
/// (see [preferenceReadIsStale]).
library;

import 'package:flutter/foundation.dart';

@immutable
class NotificationToggleState {
  const NotificationToggleState({this.stored, this.pending});

  /// The saved preference as last reported by a read that is known to be fresh,
  /// or by a write we made ourselves. Null until the first answer arrives.
  final bool? stored;

  /// The value the user just chose, held while its write is in flight.
  final bool? pending;

  /// What the switch renders.
  ///
  /// The `true` fallback applies only before anything has answered at all, and
  /// matches the column default of `users.notifications_enabled`.
  bool get displayed => pending ?? stored ?? true;

  /// True while a choice is waiting on its write.
  bool get isWriting => pending != null;

  /// The user moved the switch. Their choice shows immediately.
  NotificationToggleState userChose(bool value) =>
      NotificationToggleState(stored: stored, pending: value);

  /// The write of [value] landed. It is now the stored truth.
  ///
  /// The pending value is retired only if it is still the one we wrote — a
  /// second tap during the first write must keep waiting for ITS write.
  NotificationToggleState writeSucceeded(bool value) => NotificationToggleState(
        stored: value,
        pending: pending == value ? null : pending,
      );

  /// The write of [value] failed, so nothing was saved. Same retirement rule.
  NotificationToggleState writeFailed(bool value) => NotificationToggleState(
        stored: stored,
        pending: pending == value ? null : pending,
      );

  /// A fresh read arrived from the preference stream.
  NotificationToggleState storedValueRead(bool value) =>
      NotificationToggleState(stored: value, pending: pending);

  @override
  bool operator ==(Object other) =>
      other is NotificationToggleState &&
      other.stored == stored &&
      other.pending == pending;

  @override
  int get hashCode => Object.hash(stored, pending);

  @override
  String toString() =>
      'NotificationToggleState(stored: $stored, pending: $pending)';
}

/// Whether a preference read may still be published.
///
/// [epochAtRequest] is the write counter read just before the query was sent,
/// [epochNow] the counter when its answer came back. A difference means a write
/// landed while the read was in flight, so the read describes the state BEFORE
/// that write and publishing it would undo a change the user just made.
bool preferenceReadIsStale({
  required int epochAtRequest,
  required int epochNow,
}) =>
    epochAtRequest != epochNow;
