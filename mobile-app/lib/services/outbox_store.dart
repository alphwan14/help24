import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/post_model.dart';
import '../providers/connectivity_provider.dart';
import '../utils/error_mapper.dart';
import 'cache_service.dart';
import 'chat_attachments.dart' show ChatUploads;
import 'outbox_delivery.dart';
import 'session_scope.dart';

/// THE OUTBOX IS NOT A SCREEN'S PROPERTY.
///
/// WHAT WAS WRONG
/// --------------
/// A message composed offline was queued correctly, persisted correctly, and
/// then owned by nothing but `_ChatScreenState`. Two consequences, both
/// reproduced on the S20+ against production:
///
///   * The Messages tab renders `Conversation.lastMessage`, which comes only
///     from the server `chats.last_message` column — written inside
///     `sendMessage` AFTER a successful insert. So leaving the conversation
///     showed the PREVIOUS message as the latest one, with nothing to say a
///     newer message was still waiting. The user's own words were simply gone
///     from the list.
///   * The auto-resend was a `ConnectivityProvider.onReconnect` subscription
///     opened in `ChatScreen.initState` and cancelled in its `dispose`. Leave
///     the thread and the queue has no listener: the network came back, stayed
///     up, and the message was STILL undelivered a minute later. It could only
///     ever be sent by re-opening that exact conversation.
///
/// Both are the same defect — the queue outlives the screen, so the screen
/// cannot be its owner. This class is that owner: it lives for the session,
/// answers "what is still unsent in this chat?" synchronously for the list, and
/// drains on the app-wide reconnect edge whatever screen is on top.
///
/// WHAT IT DELIBERATELY IS NOT
/// ---------------------------
/// It is NOT a second store. The on-disk format is untouched — the same
/// `CacheService.saveOutbox` / `loadOutbox` entries under the same uid-scoped
/// key. This is the in-memory owner of that data plus the drain that was
/// missing, so there is no new persistence to keep consistent with the old one.
///
/// TWO SENDERS WOULD MEAN TWO MESSAGES
/// -----------------------------------
/// `ChatScreen` still sends for the thread the user is looking at — that path
/// is unchanged and well evidenced. This class sends for every OTHER thread. A
/// single in-flight claim ([claimSend]) is shared by both, and the drain skips
/// [activeChatId] entirely, so one queued message can never be sent twice.
class OutboxStore extends ChangeNotifier implements SessionScoped {
  OutboxStore._();

  static final OutboxStore instance = OutboxStore._();

  /// The account these queues belong to. A read for anyone else answers empty:
  /// isolation is decided here as well as in the key, the same two defences
  /// [SessionScope] insists on everywhere else.
  String _ownerUid = '';

  /// chatId → queued messages, oldest first.
  final Map<String, List<Message>> _byChat = {};

  /// Message ids currently being sent, by whoever claimed them first.
  final Set<String> _inFlight = {};

  /// The thread the user is looking at. Its queue belongs to `ChatScreen`,
  /// which shows per-message state and a retry affordance; draining it from
  /// here as well would be a second sender for the same rows.
  String _activeChatId = '';

  StreamSubscription<void>? _reconnectSub;
  bool _started = false;

  /// Begin owning the outbox for [uid]: hydrate what a previous session left on
  /// disk, then drain on every reconnect edge for the rest of the session.
  ///
  /// Safe to call repeatedly; a different uid restarts cleanly.
  Future<void> start(String uid) async {
    final owner = uid.trim();
    if (owner.isEmpty) return;
    if (_started && _ownerUid == owner) return;
    if (_ownerUid != owner) _clear();
    _ownerUid = owner;
    _started = true;
    _reconnectSub ??= NetworkHealth.onReconnect.listen((_) {
      // A new network is a fresh budget for every transient failure.
      _transientFailures.clear();
      _retryTimer?.cancel();
      _retryTimer = null;
      _retrySignal.add(null);
      unawaited(drain());
    });
    await hydrate(owner);
    unawaited(_sweepFiles(owner));
    if (!NetworkHealth.isOffline) unawaited(drain());
  }

  /// Delete queued-attachment copies nothing refers to any more. Runs after
  /// hydration, so every copy a persisted queue still needs is in [_byChat].
  Future<void> _sweepFiles(String owner) async {
    final keep = <String>{
      for (final queue in _byChat.values)
        for (final m in queue)
          if (m.localPath != null) m.localPath!,
    };
    final removed = await OutboxFiles.sweep(uid: owner, keep: keep);
    if (removed > 0) debugPrint('[OUTBOX] swept $removed orphaned attachment copies');
  }

  /// When to try again: the reconnect edge, or the short transient-retry timer
  /// (see [statusAfterFailure]). `ChatScreen` listens to this for the thread
  /// it owns; this store drains every other thread on the same signal, so both
  /// senders act on one definition of "now is worth trying".
  Stream<void> get retrySignal => _retrySignal.stream;
  final StreamController<void> _retrySignal = StreamController<void>.broadcast();

  /// Whichever thread is on screen, or '' when none is.
  void setActiveChat(String chatId) => _activeChatId = chatId.trim();

  // ── Reads ─────────────────────────────────────────────────────────────────

  /// The newest message still waiting to reach the server for [chatId], or null
  /// when the chat has nothing queued.
  ///
  /// Synchronous on purpose: `_ConversationTile` needs an answer inside
  /// `build`, and an async gap there is how a list flickers between the real
  /// preview and the pending one on every rebuild.
  Message? pendingFor(String uid, String chatId) {
    if (uid.isEmpty || uid != _ownerUid) return null;
    final queue = _byChat[chatId];
    if (queue == null || queue.isEmpty) return null;
    return queue.reduce((a, b) => b.timestamp.isAfter(a.timestamp) ? b : a);
  }

  /// Whether anything queued for [chatId] has actually FAILED, as distinct from
  /// merely waiting. The two must not render identically: one is the app doing
  /// its job, the other needs the user.
  bool hasFailure(String uid, String chatId) {
    if (uid.isEmpty || uid != _ownerUid) return false;
    final queue = _byChat[chatId];
    if (queue == null) return false;
    return queue.any((m) => m.status == OutboxStatus.failed);
  }

  @visibleForTesting
  List<Message> queueFor(String chatId) =>
      List<Message>.unmodifiable(_byChat[chatId] ?? const <Message>[]);

  // ── Writes ────────────────────────────────────────────────────────────────

  /// Record the current queue for one chat. Called from `ChatScreen`'s single
  /// persistence choke point, so every add, status change and successful send
  /// reaches the Messages tab without that screen knowing the tab exists.
  void publish(String uid, String chatId, List<Message> queue) {
    if (uid.isEmpty || chatId.isEmpty) return;
    if (_ownerUid.isEmpty) _ownerUid = uid;
    if (uid != _ownerUid) return;
    if (queue.isEmpty) {
      if (_byChat.remove(chatId) == null) return;
    } else {
      _byChat[chatId] = List<Message>.of(queue)
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }
    notifyListeners();
  }

  /// Claim exclusive right to send [messageId]. Returns false when someone
  /// already holds it — the guard that makes two senders safe.
  bool claimSend(String messageId) => _inFlight.add(messageId);

  void releaseSend(String messageId) => _inFlight.remove(messageId);

  bool isSending(String messageId) => _inFlight.contains(messageId);

  // ── Hydration ─────────────────────────────────────────────────────────────

  /// Read every queue this account left on disk, in ONE pass over the keys.
  ///
  /// `SharedPreferences` holds its keys in memory, so this is a filter over a
  /// map rather than N round trips — which is what makes it affordable to do at
  /// startup rather than lazily per row.
  Future<void> hydrate(String uid) async {
    final owner = uid.trim();
    if (owner.isEmpty) return;
    try {
      final prefix = SessionScope.scopedKey(SessionKeys.outbox, owner, '');
      final prefs = await SharedPreferences.getInstance();
      final chatIds = prefs
          .getKeys()
          .where((k) => k.startsWith(prefix) && k.length > prefix.length)
          .map((k) => k.substring(prefix.length))
          .toList();
      var changed = false;
      for (final chatId in chatIds) {
        if (_ownerUid != owner) return; // session moved on mid-read
        final queued = await CacheService.loadOutbox(chatId, owner);
        if (queued.isEmpty) continue;
        // An in-memory queue is fresher than disk by definition — the screen
        // that owns it may already have sent or failed some of these.
        if (_byChat.containsKey(chatId)) continue;
        _byChat[chatId] = queued
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
        changed = true;
      }
      if (changed) notifyListeners();
    } catch (e) {
      debugPrint('[OUTBOX] hydrate failed: $e');
    }
  }

  // ── Draining ──────────────────────────────────────────────────────────────

  /// Send everything queued for chats the user is NOT currently looking at.
  ///
  /// Oldest first within a chat, so a queue drains in the order it was written.
  /// A failure leaves the message queued and marked — never dropped, and never
  /// retried in a tight loop: the next reconnect edge tries again.
  Future<void> drain() async {
    final owner = _ownerUid;
    if (owner.isEmpty || NetworkHealth.isOffline || _draining) return;
    // `claimSend` already makes a concurrent drain harmless; this just stops it
    // being wasteful when reconnect edges arrive in a burst.
    _draining = true;
    try {
      final chatIds = _byChat.keys.where((id) => id != _activeChatId).toList();
      for (final chatId in chatIds) {
        final queue = List<Message>.of(_byChat[chatId] ?? const <Message>[]);
        for (final message in queue) {
          if (_ownerUid != owner || NetworkHealth.isOffline) return;
          // The user opened this thread while we were working; it owns the rest.
          if (chatId == _activeChatId) break;
          await _send(owner, chatId, message);
        }
      }
    } finally {
      _draining = false;
    }
  }

  bool _draining = false;

  Future<void> _send(String uid, String chatId, Message message) async {
    if (!claimSend(message.id)) return;
    try {
      await OutboxDelivery.deliver(
        senderId: uid,
        chatId: chatId,
        message: message,
        // Persist the uploaded URL at once: a retry after this point must
        // write the row, not store the file a second time.
        onUploaded: (uploaded) => _replaceAndPersist(uid, chatId, uploaded),
      );
      clearFailures(message.id);
      _removeAndPersist(uid, chatId, message.id);
      debugPrint('[OUTBOX] sent queued ${message.type} chat=$chatId');
    } catch (e) {
      final serverId = OutboxIds.serverIdOf(message.id);
      if (serverId != null && ChatUploads.isCancelled(serverId)) {
        // Withdrawn by the user, not failed: it leaves the queue.
        _removeAndPersist(uid, chatId, message.id);
        unawaited(OutboxFiles.discard(message.localPath));
        return;
      }
      debugPrint('[OUTBOX] send failed chat=$chatId type=${message.type}: $e');
      _markAndPersist(uid, chatId, message.id, statusAfterFailure(message.id, e));
    } finally {
      releaseSend(message.id);
    }
  }

  // ── Failure policy ────────────────────────────────────────────────────────

  /// Transient failures per message on the current network, reset by a
  /// reconnect edge or a success.
  final Map<String, int> _transientFailures = {};
  Timer? _retryTimer;

  /// How long to wait before each automatic re-attempt after a transient
  /// failure that did NOT take the app offline (a blip, a dropped upload, a
  /// brief server outage). Three, then the message is marked failed.
  static const List<Duration> transientRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
  ];

  /// WHAT A FAILED ATTEMPT MEANS FOR THE MESSAGE — decided in one place for
  /// both senders.
  ///
  ///   * The app is offline → `queued`. Nothing went wrong that the user must
  ///     act on; the reconnect edge will send it.
  ///   * A transient failure while online (socket dropped mid-upload, timeout,
  ///     5xx) → `queued`, and a short timer tries again. After
  ///     [transientRetryDelays] is exhausted → `failed`.
  ///   * Anything else — refused by the server, a restricted account, the
  ///     queued file gone → `failed` at once. Retrying on a timer cannot fix
  ///     it; the bubble says "Couldn't send" and offers Retry.
  ///
  /// Never removes the message: a failure is a status, not a deletion.
  String statusAfterFailure(String messageId, Object error) {
    // Logs the true cause and fires the restriction hook when the database
    // refused a restricted account — the user is told why elsewhere.
    final category = error is OutboxPermanentFailure
        ? ErrorCategory.unknown
        : ErrorMapper.toFailure(error, context: ErrorContext.sendMessage).category;
    final transient = isTransientCategory(category);
    if (NetworkHealth.isOffline) return OutboxStatus.queued;
    if (!transient) {
      _transientFailures.remove(messageId);
      return OutboxStatus.failed;
    }
    final attempts = (_transientFailures[messageId] ?? 0) + 1;
    if (attempts > transientRetryDelays.length) {
      _transientFailures.remove(messageId);
      return OutboxStatus.failed;
    }
    _transientFailures[messageId] = attempts;
    _armRetry(transientRetryDelays[attempts - 1]);
    return OutboxStatus.queued;
  }

  /// A failure the network or the server may recover from by itself.
  static bool isTransientCategory(ErrorCategory category) =>
      category == ErrorCategory.networkOffline ||
      category == ErrorCategory.networkTimeout ||
      category == ErrorCategory.serverUnavailable ||
      category == ErrorCategory.rateLimited;

  /// Forget [messageId]'s transient failures — on delivery, or when the user
  /// retries by hand and so earns a fresh budget.
  void clearFailures(String messageId) => _transientFailures.remove(messageId);

  void _armRetry(Duration delay) {
    if (_retryTimer?.isActive ?? false) return;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (NetworkHealth.isOffline) return; // the reconnect edge will do it
      _retrySignal.add(null);
      unawaited(drain());
    });
  }

  void _replaceAndPersist(String uid, String chatId, Message updated) {
    final queue = _byChat[chatId];
    if (queue == null) return;
    final i = queue.indexWhere((m) => m.id == updated.id);
    if (i == -1) return;
    queue[i] = updated;
    unawaited(CacheService.saveOutbox(uid, chatId, List<Message>.of(queue)));
  }

  void _removeAndPersist(String uid, String chatId, String messageId) {
    final queue = _byChat[chatId];
    if (queue == null) return;
    queue.removeWhere((m) => m.id == messageId);
    if (queue.isEmpty) _byChat.remove(chatId);
    unawaited(CacheService.saveOutbox(
        uid, chatId, List<Message>.of(_byChat[chatId] ?? const <Message>[])));
    notifyListeners();
  }

  void _markAndPersist(
      String uid, String chatId, String messageId, String status) {
    final queue = _byChat[chatId];
    if (queue == null) return;
    final i = queue.indexWhere((m) => m.id == messageId);
    if (i == -1 || queue[i].status == status) return;
    queue[i] = queue[i].copyWith(status: status);
    unawaited(CacheService.saveOutbox(uid, chatId, List<Message>.of(queue)));
    notifyListeners();
  }

  // ── Session boundary ──────────────────────────────────────────────────────

  @override
  void resetForSignOut() {
    // The queue's persisted entries are purged by prefix at this boundary;
    // the attachment copies they referenced go with them. Fire-and-forget:
    // sign-out must never wait on cleanup.
    final owner = _ownerUid;
    if (owner.isNotEmpty) unawaited(OutboxFiles.purgeUser(owner));
    _clear();
    _ownerUid = '';
    _started = false;
    notifyListeners();
  }

  void _clear() {
    _byChat.clear();
    _inFlight.clear();
    _activeChatId = '';
    _transientFailures.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  @visibleForTesting
  void debugSeed(String uid, Map<String, List<Message>> queues) {
    _ownerUid = uid;
    _byChat
      ..clear()
      ..addAll(queues);
  }
}

/// Statuses an outbound message can hold before the server has it.
///
/// `queued` and `sending` were one value, and the difference matters: offline
/// nothing is in progress, so an indeterminate spinner claims work that is not
/// happening. A clock says the true thing — this is waiting for a network.
class OutboxStatus {
  OutboxStatus._();

  /// Composed while offline (or after a failed attempt was re-queued). Waiting
  /// for a network; nothing is in flight.
  static const String queued = 'queued';

  /// A request is actually open right now.
  static const String sending = 'sending';

  /// The attempt completed and did not succeed. Needs the user or a reconnect.
  static const String failed = 'failed';

  /// True for anything that has not reached the server.
  static bool isUnsent(String status) =>
      status == queued || status == sending || status == failed;
}
