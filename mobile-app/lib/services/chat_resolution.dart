/// Whether a conversation exists — as distinct from whether we have looked yet.
///
/// Exists because of a real-device/production finding (messaging-readiness
/// report §D1): `ChatScreen` treated an empty `Conversation.id` as proof that
/// no conversation existed, and rendered "Start the conversation". The id was
/// simply unknown — most entry points (provider profile, applications, post
/// detail, saved) construct `Conversation(id: '')` and never had one.
///
/// The lookup itself was correct and already written; it just ran too late,
/// inside `createChat` on FIRST SEND. So the user saw an empty thread, sent a
/// message, and watched months of history appear underneath it.
///
/// Three states are not enough here, and that is the whole point. "We looked
/// and there is nothing" and "we could not look" must never collapse into the
/// same UI, because the second one offline would invite the user to start a
/// second conversation alongside one that already exists.
library;

enum ChatResolution {
  /// The lookup is in flight. Show progress — NEVER "Start the conversation".
  resolving,

  /// A conversation exists and its canonical UUID is adopted.
  existing,

  /// We asked, the answer came back, and there genuinely is no conversation.
  /// This is the ONLY state permitted to offer "Start the conversation".
  absent,

  /// The lookup could not complete (offline, RLS, 5xx). We do not know.
  /// Treated as "not absent": no start-conversation prompt, and any cached
  /// thread stays on screen.
  unresolved,
}

/// Decide the state from what the caller knew and what the lookup returned.
///
/// [knownId] is true when the entry point already supplied a chat UUID (the
/// Messages tab, an FCM tap, the notifications list) — those never need a
/// lookup and are `existing` immediately.
ChatResolution chatResolutionFor({
  required bool knownId,
  required bool lookupDone,
  required bool lookupSucceeded,
  required bool found,
}) {
  if (knownId) return ChatResolution.existing;
  if (!lookupDone) return ChatResolution.resolving;
  if (!lookupSucceeded) return ChatResolution.unresolved;
  return found ? ChatResolution.existing : ChatResolution.absent;
}

/// The single gate for the "Start the conversation" empty state.
///
/// Deliberately narrow: an unknown answer is not an invitation to create a
/// second conversation.
bool showsStartConversation(ChatResolution resolution) =>
    resolution == ChatResolution.absent;

/// Whether the screen is still waiting on an answer, and should show progress
/// rather than any empty state.
bool showsResolvingProgress(ChatResolution resolution) =>
    resolution == ChatResolution.resolving;

/// The canonical participant ordering — half of conversation identity.
///
/// The database enforces `CHECK (user1 < user2)` and keys its two unique
/// indexes on `(user1, user2[, post_id])`, so a lookup that ordered the pair
/// differently from the writer would miss an existing conversation and invite a
/// duplicate. Single-sourced here because three call sites need it and they
/// must not be allowed to drift.
///
/// Returns null for input that cannot name a conversation (empty ids, or a
/// self-chat, which the DB check constraint also forbids).
({String user1, String user2})? canonicalPair(String a, String b) {
  final idA = a.trim();
  final idB = b.trim();
  if (idA.isEmpty || idB.isEmpty || idA == idB) return null;
  return idA.compareTo(idB) <= 0
      ? (user1: idA, user2: idB)
      : (user1: idB, user2: idA);
}
