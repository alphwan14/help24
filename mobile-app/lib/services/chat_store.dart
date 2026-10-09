import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_person.dart';
import '../models/post_model.dart';
import 'session_scope.dart';

/// THE CHAT DATABASE — the one place every chat screen reads from.
///
/// WHY A DATABASE
/// --------------
/// Chat used to be cached as SharedPreferences JSON blobs: one key for the
/// conversation list, one per thread, one per outbox. Three things went wrong
/// with that, all reproduced on the S20+:
///   * the list blob was a SNAPSHOT of the last fetch, people included, so a
///     fetch whose profile lookup failed overwrote every name with "?" — on
///     screen and on disk (see `chat_person.dart`);
///   * there was no record of a person apart from the row that mentioned
///     them, so nothing could remember a name the phone had already learned;
///   * Android rewrites the whole preferences XML on every save, and loads the
///     whole of it at startup, so every cached message made every write and
///     every launch a little slower.
///
/// THE RULES (WhatsApp's msgstore/wa.db, Telegram's "messages imply users",
/// Messenger's LightSpeed, Android's offline-first guidance — same idea):
///   * screens render from here; the network only WRITES here (`ChatSync`);
///   * people are stored as people (`users`), and every conversation also
///     keeps its participant's last known name, so a missed lookup can never
///     cost a name the phone already had;
///   * nothing but an explicit sign-out (or an account switch) deletes it —
///     not a 401, not an expired token, not an app update (the schema is
///     migrated, never wiped).
///
/// ONE FILE PER ACCOUNT, in app-private storage (`databases/`), excluded from
/// cloud backup (`res/xml/data_extraction_rules.xml`). Android encrypts that
/// storage at rest with the device's file-based encryption; the file and the
/// media beside it are deleted at sign-out.
///
/// SQLITE 3.9. minSdk 24 ships SQLite 3.9.2, which has no `ON CONFLICT DO
/// UPDATE`, no window functions and no JSON1. Upserts are therefore an
/// `INSERT OR IGNORE` followed by an `UPDATE` of the columns the server owns,
/// sent together in one batch — which is also what keeps columns only this
/// phone knows (a downloaded thumbnail, a pinned job snapshot) from being
/// overwritten by a sync.
class ChatStore implements SessionScoped, SessionPurgeable {
  ChatStore._();

  static final ChatStore instance = ChatStore._();

  /// v1: users, conversations, messages, outbox, sync_state.
  static const int schemaVersion = 1;

  /// Where the database files live, instead of the platform's databases
  /// directory. Tests point this at a temp folder.
  @visibleForTesting
  static String? directoryOverride;

  /// The SQLite implementation. Tests use sqflite_common_ffi.
  @visibleForTesting
  static DatabaseFactory? factoryOverride;

  static DatabaseFactory get _factory => factoryOverride ?? databaseFactory;

  static const String _filePrefix = 'help24_chat_';

  /// The database file for [uid]. The uid is the file's name, so a read for
  /// one account cannot open another account's file — the isolation is
  /// structural, as it is for every uid-scoped key in [SessionScope].
  static String fileNameFor(String uid) =>
      '$_filePrefix${uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.db';

  final Map<String, Future<Database>> _open = {};

  final StreamController<ChatChange> _changes = StreamController<ChatChange>.broadcast();

  /// Every write, described. Screens listen and re-read what they show.
  Stream<ChatChange> get changes => _changes.stream;

  void _emit(String uid, ChatChange change) {
    if (!_changes.isClosed) _changes.add(change.withOwner(uid));
  }

  /// The database for [uid], opened (and created or migrated) on first use.
  ///
  /// Never throws: a store that cannot open behaves as an empty one, and the
  /// app degrades to network-only rather than failing to show chat at all.
  Future<Database?> _db(String uid) async {
    final owner = uid.trim();
    if (owner.isEmpty || _sealed.contains(owner)) return null;
    final opening = _open.putIfAbsent(owner, () => _openFor(owner));
    try {
      return await opening;
    } catch (e) {
      debugPrint('[CHAT_DB] open failed for this account: $e');
      if (identical(_open[owner], opening)) _open.remove(owner);
      return null;
    }
  }

  /// Open the store for [uid] ahead of the first read, so the Messages tab's
  /// first frame is not the one that pays for creating the schema. Also the
  /// one way to unseal an account after its sign-out (see [purgeOwner]).
  Future<bool> open(String uid) async {
    _sealed.remove(uid.trim());
    return await _db(uid) != null;
  }

  /// Accounts signed out of in this process, until a session opens them
  /// again. A write still in flight when the session ended — a queued outbox
  /// persist, the tail of a sync — would otherwise re-create the file that
  /// was just deleted.
  final Set<String> _sealed = {};

  static Future<String> _directory() async =>
      directoryOverride ?? await _factory.getDatabasesPath();

  Future<Database> _openFor(String uid) async {
    final watch = Stopwatch()..start();
    final dir = await _directory();
    await Directory(dir).create(recursive: true);
    final path = '$dir/${fileNameFor(uid)}';
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: _configure,
        onCreate: (db, _) => _createSchema(db),
        onUpgrade: _upgrade,
      ),
    );
    await _importLegacyCache(db, uid);
    int? bytes;
    try {
      bytes = await File(path).length();
    } catch (_) {}
    debugPrint('[CHAT_DB] open +${watch.elapsedMilliseconds}ms '
        'size=${bytes == null ? 'unknown' : '${(bytes / 1024).toStringAsFixed(0)}KB'}');
    return db;
  }

  static Future<void> _configure(Database db) async {
    // WAL lets the FCM background isolate write a pushed message while the
    // app's own connection reads; busy_timeout makes the rare overlap of two
    // writers wait instead of failing. PRAGMAs that answer a row go through
    // rawQuery — Android's execute() refuses them.
    try {
      await db.rawQuery('PRAGMA journal_mode=WAL');
      await db.rawQuery('PRAGMA busy_timeout=5000');
    } catch (e) {
      debugPrint('[CHAT_DB] pragma: $e');
    }
  }

  static Future<void> _createSchema(Database db) async {
    final batch = db.batch()
      ..execute('''
        CREATE TABLE users(
          id TEXT PRIMARY KEY NOT NULL,
          display_name TEXT,
          avatar_url TEXT,
          avatar_path TEXT,
          avatar_version TEXT,
          role TEXT,
          profession TEXT,
          rating REAL,
          completed_jobs INTEGER,
          last_seen INTEGER,
          updated_at INTEGER NOT NULL
        )''')
      ..execute('''
        CREATE TABLE conversations(
          id TEXT PRIMARY KEY NOT NULL,
          participant_id TEXT NOT NULL,
          participant_name TEXT,
          participant_avatar_url TEXT,
          participant_avatar_path TEXT,
          post_id TEXT,
          post_title TEXT,
          job_snapshot TEXT,
          job_snapshot_at INTEGER,
          last_message TEXT NOT NULL DEFAULT '',
          last_message_at INTEGER NOT NULL,
          unread_count INTEGER NOT NULL DEFAULT 0,
          server_updated_at TEXT,
          thread_synced_at INTEGER,
          updated_at INTEGER NOT NULL
        )''')
      ..execute('CREATE INDEX idx_conversations_recent ON conversations(last_message_at DESC)')
      ..execute('''
        CREATE TABLE messages(
          id TEXT PRIMARY KEY NOT NULL,
          client_id TEXT,
          conversation_id TEXT NOT NULL,
          sender_id TEXT NOT NULL,
          type TEXT NOT NULL DEFAULT 'text',
          body TEXT NOT NULL DEFAULT '',
          attachment_url TEXT,
          thumb_path TEXT,
          file_path TEXT,
          latitude REAL,
          longitude REAL,
          live_until INTEGER,
          status TEXT NOT NULL DEFAULT 'sent',
          seen_at INTEGER,
          delivered_at INTEGER,
          deleted_for_everyone INTEGER NOT NULL DEFAULT 0,
          reply_to_id TEXT,
          reply_to_sender TEXT,
          reply_to_preview TEXT,
          created_at INTEGER NOT NULL
        )''')
      ..execute('CREATE INDEX idx_messages_thread ON messages(conversation_id, created_at)')
      ..execute('''
        CREATE TABLE outbox(
          id TEXT PRIMARY KEY NOT NULL,
          conversation_id TEXT NOT NULL,
          position INTEGER NOT NULL,
          payload TEXT NOT NULL
        )''')
      ..execute('CREATE INDEX idx_outbox_conversation ON outbox(conversation_id, position)')
      ..execute('CREATE TABLE sync_state(key TEXT PRIMARY KEY NOT NULL, value TEXT)');
    await batch.commit(noResult: true);
  }

  /// Schema migrations, oldest first. An app update MIGRATES the chat history;
  /// wiping it would turn every update into an offline-empty Messages tab.
  static Future<void> _upgrade(Database db, int from, int to) async {
    // v1 is the first schema. Add `if (from < 2) { ... }` blocks here.
  }

  // ── Legacy import ──────────────────────────────────────────────────────────

  static const String _legacyImportKey = 'legacy_prefs_import_v1';

  /// Move the SharedPreferences chat cache of builds ≤1.0.2 into the database,
  /// once, then delete it.
  ///
  /// The point is that updating the app is not a reason to lose offline chat:
  /// a user who opens the new build on a bus must see what the old build had.
  /// A name stored as "?" by the old bug is imported as UNKNOWN — the poison
  /// does not survive the move.
  Future<void> _importLegacyCache(Database db, String uid) async {
    try {
      final done = await db.query('sync_state',
          where: 'key = ?', whereArgs: [_legacyImportKey], limit: 1);
      if (done.isNotEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final convKey = SessionScope.scopedKey(SessionKeys.conversations, uid);
      final threadPrefix = SessionScope.scopedKey(SessionKeys.messages, uid, '');
      final outboxPrefix = SessionScope.scopedKey(SessionKeys.outbox, uid, '');
      final conversations = <Conversation>[];
      final threads = <String, List<Message>>{};
      final outboxes = <String, List<Message>>{};
      final consumed = <String>[];

      final convJson = prefs.getString(convKey);
      if (convJson != null && convJson.isNotEmpty) {
        consumed.add(convKey);
        for (final row in (jsonDecode(convJson) as List)) {
          conversations.add(Conversation.fromCacheMap(Map<String, dynamic>.from(row as Map)));
        }
      }
      for (final key in prefs.getKeys()) {
        final isThread = key.startsWith(threadPrefix) && key.length > threadPrefix.length;
        final isOutbox = key.startsWith(outboxPrefix) && key.length > outboxPrefix.length;
        if (!isThread && !isOutbox) continue;
        final raw = prefs.getString(key);
        consumed.add(key);
        if (raw == null || raw.isEmpty) continue;
        final chatId = key.substring((isThread ? threadPrefix : outboxPrefix).length);
        final list = [
          for (final row in (jsonDecode(raw) as List))
            Message.fromJson(Map<String, dynamic>.from(row as Map), uid),
        ];
        (isThread ? threads : outboxes)[chatId] = list;
      }

      await db.transaction((txn) async {
        final batch = txn.batch();
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final c in conversations) {
          _putConversation(batch, c, now: now);
          if (c.participantId.isNotEmpty) {
            _putPerson(batch, ChatPerson(
              id: c.participantId,
              name: ChatPeople.knownOrNull(c.userName),
              avatarUrl: c.userAvatar.isEmpty ? null : c.userAvatar,
              lastSeen: c.lastSeen,
            ), now: now, profileKnown: false);
          }
        }
        threads.forEach((chatId, list) {
          for (final m in list) {
            _putMessage(batch, chatId, m);
          }
        });
        outboxes.forEach((chatId, list) {
          for (var i = 0; i < list.length; i++) {
            _putOutbox(batch, chatId, i, list[i]);
          }
        });
        batch.insert('sync_state', {'key': _legacyImportKey, 'value': '$now'},
            conflictAlgorithm: ConflictAlgorithm.replace);
        await batch.commit(noResult: true);
      });
      for (final key in consumed) {
        await prefs.remove(key);
      }
      if (consumed.isNotEmpty) {
        debugPrint('[CHAT_DB] imported legacy cache: ${conversations.length} conversations, '
            '${threads.length} threads, ${outboxes.length} outboxes');
      }
    } catch (e) {
      // The legacy keys stay where they are and the import is retried on the
      // next open. Nothing is lost by failing here.
      debugPrint('[CHAT_DB] legacy import failed: $e');
    }
  }

  // ── Row writers (batch members, no awaits) ─────────────────────────────────

  static int _ms(DateTime t) => t.toUtc().millisecondsSinceEpoch;
  static int? _msOrNull(DateTime? t) => t == null ? null : _ms(t);
  static DateTime _time(Object? ms) =>
      DateTime.fromMillisecondsSinceEpoch((ms as num?)?.toInt() ?? 0, isUtc: true);
  static DateTime? _timeOrNull(Object? ms) => ms == null ? null : _time(ms);

  /// A conversation row. Its participant's name and photo are written only
  /// when KNOWN: an unknown name never replaces a known one.
  static void _putConversation(
    Batch batch,
    Conversation c, {
    required int now,
    String? serverUpdatedAt,
  }) {
    final name = ChatPeople.knownOrNull(c.userName);
    batch.insert(
      'conversations',
      {
        'id': c.id,
        'participant_id': c.participantId,
        'participant_name': name,
        'participant_avatar_url': c.userAvatar.isEmpty ? null : c.userAvatar,
        'post_id': c.postId,
        'post_title': c.postTitle,
        'last_message': c.lastMessage,
        'last_message_at': _ms(c.lastMessageTime),
        'unread_count': c.unreadCount,
        'server_updated_at': serverUpdatedAt,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    batch.update(
      'conversations',
      {
        'participant_id': c.participantId,
        'post_id': c.postId,
        'post_title': c.postTitle,
        'last_message': c.lastMessage,
        'last_message_at': _ms(c.lastMessageTime),
        'unread_count': c.unreadCount,
        if (serverUpdatedAt != null) 'server_updated_at': serverUpdatedAt,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [c.id],
    );
    if (name != null) {
      batch.update('conversations', {'participant_name': name},
          where: 'id = ?', whereArgs: [c.id]);
    }
  }

  /// A person. [profileKnown] means [p] came from a successful profile read,
  /// so its photo address is the truth even when it is empty (the photo was
  /// removed); otherwise only what [p] actually carries is written.
  static void _putPerson(
    Batch batch,
    ChatPerson p, {
    required int now,
    required bool profileKnown,
  }) {
    final name = ChatPeople.knownOrNull(p.name);
    final avatar = (p.avatarUrl ?? '').trim();
    batch.insert(
      'users',
      {
        'id': p.id,
        'display_name': name,
        'avatar_url': avatar.isEmpty ? null : avatar,
        'profession': p.profession,
        'last_seen': _msOrNull(p.lastSeen),
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    batch.update(
      'users',
      {
        if (name != null) 'display_name': name,
        if (profileKnown || avatar.isNotEmpty) 'avatar_url': avatar.isEmpty ? null : avatar,
        // A removed photo takes its file with it.
        if (profileKnown && avatar.isEmpty) 'avatar_path': null,
        if (profileKnown && avatar.isEmpty) 'avatar_version': null,
        if (profileKnown || p.profession != null) 'profession': p.profession,
        if (p.lastSeen != null) 'last_seen': _msOrNull(p.lastSeen),
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [p.id],
    );
  }

  static Map<String, Object?> _messageColumns(String chatId, Message m) => {
        'conversation_id': chatId,
        'client_id': m.id,
        'sender_id': m.senderId,
        'type': m.type,
        'body': m.text,
        'attachment_url': m.attachmentUrl,
        'latitude': m.latitude,
        'longitude': m.longitude,
        'live_until': _msOrNull(m.liveUntil),
        'status': m.status,
        'seen_at': _msOrNull(m.seenAt),
        'delivered_at': _msOrNull(m.deliveredAt),
        'deleted_for_everyone': m.deletedForEveryone ? 1 : 0,
        'reply_to_id': m.replyToId,
        'reply_to_sender': m.replyToSender,
        'reply_to_preview': m.replyToPreview,
        'created_at': _ms(m.timestamp),
      };

  /// A server message. Local columns (thumb_path, file_path) are left alone,
  /// and the outbox copy of the same message — `pending_<id>` — is removed in
  /// the same batch: once the server has the row, its queued copy is done,
  /// whichever path delivered it. That is the de-duplication by client id.
  static void _putMessage(Batch batch, String chatId, Message m) {
    if (m.id.isEmpty || m.id.startsWith('pending_')) return;
    final columns = _messageColumns(chatId, m);
    batch.insert('messages', {'id': m.id, ...columns},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    batch.update('messages', columns, where: 'id = ?', whereArgs: [m.id]);
    batch.delete('outbox', where: 'id = ?', whereArgs: ['pending_${m.id}']);
  }

  static void _putOutbox(Batch batch, String chatId, int position, Message m) {
    batch.insert(
      'outbox',
      {
        'id': m.id,
        'conversation_id': chatId,
        'position': position,
        'payload': jsonEncode(m.toCacheMap()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Message _messageFromRow(Map<String, Object?> r, String ownerUid) {
    final sender = (r['sender_id'] as String?) ?? '';
    return Message(
      id: r['id'] as String,
      conversationId: r['conversation_id'] as String,
      senderId: sender,
      text: (r['body'] as String?) ?? '',
      timestamp: _time(r['created_at']),
      isMe: sender == ownerUid,
      type: (r['type'] as String?) ?? 'text',
      latitude: (r['latitude'] as num?)?.toDouble(),
      longitude: (r['longitude'] as num?)?.toDouble(),
      liveUntil: _timeOrNull(r['live_until']),
      attachmentUrl: r['attachment_url'] as String?,
      status: (r['status'] as String?) ?? 'sent',
      seenAt: _timeOrNull(r['seen_at']),
      deliveredAt: _timeOrNull(r['delivered_at']),
      deletedForEveryone: (r['deleted_for_everyone'] as int? ?? 0) == 1,
      replyToId: r['reply_to_id'] as String?,
      replyToSender: r['reply_to_sender'] as String?,
      replyToPreview: r['reply_to_preview'] as String?,
    );
  }

  // ── Conversations ──────────────────────────────────────────────────────────

  static const String _conversationSelect = '''
    SELECT c.*, u.id AS u_id, u.display_name AS u_name, u.avatar_url AS u_avatar_url,
           u.avatar_path AS u_avatar_path, u.last_seen AS u_last_seen
    FROM conversations c LEFT JOIN users u ON u.id = c.participant_id''';

  static Conversation _conversationFromRow(Map<String, Object?> r) {
    // The person's own record wins; the conversation's copy is the fallback
    // that keeps a name on screen when the person record has none.
    final name = ChatPeople.knownOrNull(r['u_name'] as String?) ??
        ChatPeople.knownOrNull(r['participant_name'] as String?);
    // The photo follows the same rule, with one difference: a person record
    // that says "no photo" is believed (the photo was removed), so the
    // conversation's copy is only used when there is no person record at all.
    final hasPerson = r['u_id'] != null;
    final avatarUrl = (hasPerson ? r['u_avatar_url'] : r['participant_avatar_url']) as String?;
    final avatarPath = (hasPerson ? r['u_avatar_path'] : r['participant_avatar_path']) as String?;
    return Conversation(
      id: r['id'] as String,
      participantId: (r['participant_id'] as String?) ?? '',
      // Empty means unknown; renderers show `ChatPeople.displayName`, never "?".
      userName: name ?? '',
      userAvatar: avatarUrl ?? '',
      userAvatarPath: avatarPath,
      lastMessage: (r['last_message'] as String?) ?? '',
      lastMessageTime: _time(r['last_message_at']),
      unreadCount: (r['unread_count'] as int?) ?? 0,
      postId: r['post_id'] as String?,
      postTitle: r['post_title'] as String?,
      lastSeen: _timeOrNull(r['u_last_seen']),
    );
  }

  /// Every stored conversation for [uid], most recent first.
  Future<List<Conversation>> loadConversations(String uid) async {
    final db = await _db(uid);
    if (db == null) return const [];
    try {
      final rows = await db.rawQuery('$_conversationSelect ORDER BY c.last_message_at DESC');
      return rows.map(_conversationFromRow).toList();
    } catch (e) {
      debugPrint('[CHAT_DB] loadConversations: $e');
      return const [];
    }
  }

  /// Whether this account has any stored conversation — without reading them.
  Future<bool> hasConversations(String uid) async {
    final db = await _db(uid);
    if (db == null) return false;
    final rows = await db.rawQuery('SELECT 1 FROM conversations LIMIT 1');
    return rows.isNotEmpty;
  }

  /// The FCM background isolate wrote this account's file. Its writes cannot
  /// reach this isolate's listeners, so whoever notices (the app resuming)
  /// announces them, and every screen re-reads.
  void announceExternalWrite(String uid) =>
      _emit(uid, const ChatChange(all: true));

  /// The stored conversation with [participantId] under the same identity
  /// rule the server lookup uses: `post_id = postId` and `post_id IS NULL` are
  /// different conversations. With [mostRecent], the most recently active one
  /// whatever its post (Provider Profile → Message, §D2). Null when this
  /// phone holds none — which says nothing about the server.
  Future<Conversation?> findConversationFor(
    String uid,
    String participantId, {
    String? postId,
    bool mostRecent = false,
  }) async {
    final db = await _db(uid);
    if (db == null || participantId.isEmpty) return null;
    try {
      final post = (postId ?? '').trim();
      final String where;
      final List<Object?> args;
      if (mostRecent) {
        where = "c.participant_id = ? AND c.last_message <> ''";
        args = [participantId];
      } else if (post.isEmpty) {
        where = 'c.participant_id = ? AND c.post_id IS NULL';
        args = [participantId];
      } else {
        where = 'c.participant_id = ? AND c.post_id = ?';
        args = [participantId, post];
      }
      final rows = await db.rawQuery(
          '$_conversationSelect WHERE $where ORDER BY c.last_message_at DESC LIMIT 1', args);
      return rows.isEmpty ? null : _conversationFromRow(rows.first);
    } catch (e) {
      debugPrint('[CHAT_DB] findConversationFor: $e');
      return null;
    }
  }

  /// One conversation, or null.
  Future<Conversation?> conversation(String uid, String chatId) async {
    final db = await _db(uid);
    if (db == null || chatId.isEmpty) return null;
    try {
      final rows = await db.rawQuery('$_conversationSelect WHERE c.id = ? LIMIT 1', [chatId]);
      return rows.isEmpty ? null : _conversationFromRow(rows.first);
    } catch (e) {
      debugPrint('[CHAT_DB] conversation: $e');
      return null;
    }
  }

  /// Write one sync's worth of conversations and people, atomically.
  ///
  /// [people] holds only profiles that were actually READ; a participant
  /// missing from it keeps whatever this phone already knew. [cursor] is the
  /// newest `chats.updated_at` seen, for the next incremental sync.
  Future<void> applyConversationSync(
    String uid, {
    required List<ChatRowSnapshot> rows,
    required Map<String, ChatPerson> people,
    String? cursor,
  }) async {
    final db = await _db(uid);
    if (db == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final p in people.values) {
        _putPerson(batch, p, now: now, profileKnown: true);
        // Keep each conversation's copy of the photo in step with the read.
        final avatar = (p.avatarUrl ?? '').trim();
        batch.update(
          'conversations',
          {
            'participant_avatar_url': avatar.isEmpty ? null : avatar,
            if (avatar.isEmpty) 'participant_avatar_path': null,
          },
          where: 'participant_id = ?',
          whereArgs: [p.id],
        );
      }
      for (final row in rows) {
        final person = people[row.participantId];
        _putConversation(
          batch,
          Conversation(
            id: row.id,
            participantId: row.participantId,
            userName: person?.name ?? '',
            userAvatar: person?.avatarUrl ?? '',
            lastMessage: row.lastMessage,
            lastMessageTime: row.updatedAt,
            unreadCount: row.unreadCount,
            postId: row.postId,
            postTitle: row.postTitle,
          ),
          now: now,
          serverUpdatedAt: row.serverUpdatedAt,
        );
      }
      if (cursor != null) {
        batch.insert('sync_state', {'key': 'conversations_cursor', 'value': cursor},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
    _emit(uid, ChatChange(conversations: true, people: people.isNotEmpty));
  }

  /// Record a conversation learned outside a sync — a chat created on first
  /// send. Inserted when new; when it already exists only its post context
  /// and a KNOWN name are refreshed, because a row assembled on the send path
  /// can be older than what sync has stored (its last message and unread
  /// count must never roll back).
  Future<void> upsertConversation(String uid, Conversation c) async {
    final db = await _db(uid);
    if (db == null || c.id.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final name = ChatPeople.knownOrNull(c.userName);
    final batch = db.batch()
      ..insert(
        'conversations',
        {
          'id': c.id,
          'participant_id': c.participantId,
          'participant_name': name,
          'participant_avatar_url': c.userAvatar.isEmpty ? null : c.userAvatar,
          'post_id': c.postId,
          'post_title': c.postTitle,
          'last_message': c.lastMessage,
          'last_message_at': _ms(c.lastMessageTime),
          'unread_count': c.unreadCount,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      )
      ..update(
        'conversations',
        {
          if (c.postId != null) 'post_id': c.postId,
          if (c.postTitle != null) 'post_title': c.postTitle,
          if (name != null) 'participant_name': name,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [c.id],
      );
    await batch.commit(noResult: true);
    _emit(uid, const ChatChange(conversations: true));
  }

  /// Replace the whole list with [list]. Kept for `CacheService`'s contract
  /// (an account with no conversations persists that emptiness); the sync
  /// path uses [applyConversationSync] and never deletes.
  Future<void> replaceConversations(String uid, List<Conversation> list) async {
    final db = await _db(uid);
    if (db == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      final ids = list.map((c) => c.id).toList();
      if (ids.isEmpty) {
        await txn.delete('conversations');
      } else {
        await txn.delete('conversations',
            where: 'id NOT IN (${List.filled(ids.length, '?').join(',')})', whereArgs: ids);
      }
      final batch = txn.batch();
      for (final c in list) {
        _putConversation(batch, c, now: now);
      }
      await batch.commit(noResult: true);
    });
    _emit(uid, const ChatChange(conversations: true));
  }

  /// The unread badge, zeroed locally the moment a chat is opened — and kept
  /// at zero across a restart, which the in-memory zero alone was not.
  Future<void> markRead(String uid, String chatId) async {
    final db = await _db(uid);
    if (db == null || chatId.isEmpty) return;
    final n = await db.update('conversations', {'unread_count': 0},
        where: 'id = ? AND unread_count <> 0', whereArgs: [chatId]);
    if (n > 0) _emit(uid, const ChatChange(conversations: true));
  }

  /// The most recent [limit] conversations with what thread sync needs.
  Future<List<ThreadSyncCandidate>> recentThreads(String uid, {int limit = 30}) async {
    final db = await _db(uid);
    if (db == null) return const [];
    final rows = await db.query('conversations',
        columns: ['id', 'last_message_at', 'thread_synced_at'],
        orderBy: 'last_message_at DESC',
        limit: limit);
    return [
      for (final r in rows)
        ThreadSyncCandidate(
          chatId: r['id'] as String,
          lastMessageAt: (r['last_message_at'] as int?) ?? 0,
          threadSyncedAt: r['thread_synced_at'] as int?,
        ),
    ];
  }

  /// Record that [chatId]'s thread was fetched while the conversation's last
  /// message was at [lastMessageAt] — so it is not fetched again until the
  /// conversation moves.
  Future<void> setThreadSynced(String uid, String chatId, int lastMessageAt) async {
    final db = await _db(uid);
    if (db == null) return;
    await db.update('conversations', {'thread_synced_at': lastMessageAt},
        where: 'id = ?', whereArgs: [chatId]);
  }

  Future<String?> syncValue(String uid, String key) async {
    final db = await _db(uid);
    if (db == null) return null;
    final rows = await db.query('sync_state',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setSyncValue(String uid, String key, String value) async {
    final db = await _db(uid);
    if (db == null) return;
    await db.insert('sync_state', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// The pinned job bar's last known state for [chatId]: the lifecycle the
  /// server returned and the post it was about, as JSON.
  Future<Map<String, dynamic>?> jobSnapshot(String uid, String chatId) async {
    final db = await _db(uid);
    if (db == null || chatId.isEmpty) return null;
    final rows = await db.query('conversations',
        columns: ['job_snapshot'], where: 'id = ?', whereArgs: [chatId], limit: 1);
    final raw = rows.isEmpty ? null : rows.first['job_snapshot'] as String?;
    if (raw == null || raw.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveJobSnapshot(String uid, String chatId, Map<String, dynamic> snapshot) async {
    final db = await _db(uid);
    if (db == null || chatId.isEmpty) return;
    await db.update(
      'conversations',
      {
        'job_snapshot': jsonEncode(snapshot),
        'job_snapshot_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  // ── People ─────────────────────────────────────────────────────────────────

  Future<ChatPerson?> person(String uid, String personId) async {
    final db = await _db(uid);
    if (db == null || personId.isEmpty) return null;
    final rows = await db.query('users', where: 'id = ?', whereArgs: [personId], limit: 1);
    if (rows.isEmpty) return null;
    return _personFromRow(rows.first);
  }

  static ChatPerson _personFromRow(Map<String, Object?> r) => ChatPerson(
        id: r['id'] as String,
        name: ChatPeople.knownOrNull(r['display_name'] as String?),
        avatarUrl: r['avatar_url'] as String?,
        avatarPath: r['avatar_path'] as String?,
        avatarVersion: r['avatar_version'] as String?,
        profession: r['profession'] as String?,
        lastSeen: _timeOrNull(r['last_seen']),
      );

  /// Record what a profile read said about [people] (header presence, a
  /// profession). Names follow the same rule as everywhere: known only.
  Future<void> upsertPeople(String uid, Iterable<ChatPerson> people,
      {bool profileKnown = true}) async {
    final db = await _db(uid);
    if (db == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final p in people) {
      if (p.id.isEmpty) continue;
      _putPerson(batch, p, now: now, profileKnown: profileKnown);
    }
    await batch.commit(noResult: true);
    _emit(uid, const ChatChange(people: true));
  }

  /// Which of [ids] this phone has no name for.
  Future<Set<String>> unnamedPeople(String uid, Iterable<String> ids) async {
    final wanted = ids.where((id) => id.isNotEmpty).toSet();
    final db = await _db(uid);
    if (db == null || wanted.isEmpty) return wanted;
    final list = wanted.toList();
    final rows = await db.query('users',
        columns: ['id'],
        where: "display_name IS NOT NULL AND display_name <> '' AND id IN "
            "(${List.filled(list.length, '?').join(',')})",
        whereArgs: list);
    return wanted.difference({for (final r in rows) r['id'] as String});
  }

  /// Everyone with a photo address whose photo is not yet on this phone (or
  /// whose stored photo is an older version).
  Future<List<ChatPerson>> peopleNeedingAvatars(String uid) async {
    final db = await _db(uid);
    if (db == null) return const [];
    final rows = await db.query('users',
        where: "avatar_url IS NOT NULL AND avatar_url <> ''");
    return rows.map(_personFromRow).toList();
  }

  Future<void> setAvatarFile(String uid, String personId,
      {required String? path, required String? version}) async {
    final db = await _db(uid);
    if (db == null) return;
    await db.transaction((txn) async {
      await txn.update('users', {'avatar_path': path, 'avatar_version': version},
          where: 'id = ?', whereArgs: [personId]);
      await txn.update('conversations', {'participant_avatar_path': path},
          where: 'participant_id = ?', whereArgs: [personId]);
    });
    _emit(uid, const ChatChange(conversations: true, people: true));
  }

  // ── Messages ───────────────────────────────────────────────────────────────

  /// Insert or update server messages for [chatId]. Never deletes: a page is
  /// a window onto the thread, not the whole of it.
  Future<void> upsertMessages(String uid, String chatId, List<Message> messages) async {
    if (messages.isEmpty || chatId.isEmpty) return;
    final db = await _db(uid);
    if (db == null) return;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final m in messages) {
        _putMessage(batch, chatId, m);
      }
      await batch.commit(noResult: true);
    });
    _emit(uid, ChatChange(threads: {chatId}));
  }

  /// The newest [limit] messages of [chatId] (before [before], when given), in
  /// chronological order.
  Future<List<Message>> loadThread(
    String uid,
    String chatId, {
    int limit = 100,
    DateTime? before,
  }) async {
    final db = await _db(uid);
    if (db == null || chatId.isEmpty) return const [];
    try {
      final rows = await db.query(
        'messages',
        where: before == null ? 'conversation_id = ?' : 'conversation_id = ? AND created_at < ?',
        whereArgs: before == null ? [chatId] : [chatId, _ms(before)],
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.reversed.map((r) => _messageFromRow(r, uid)).toList();
    } catch (e) {
      debugPrint('[CHAT_DB] loadThread: $e');
      return const [];
    }
  }

  /// Delete [chatId]'s stored messages — "Clear chat" on this device.
  Future<void> clearThread(String uid, String chatId) async {
    final db = await _db(uid);
    if (db == null || chatId.isEmpty) return;
    await db.delete('messages', where: 'conversation_id = ?', whereArgs: [chatId]);
    _emit(uid, ChatChange(threads: {chatId}));
  }

  /// Photo messages in [chatIds] that have no thumbnail on this phone yet,
  /// newest first.
  Future<List<Message>> imagesWithoutThumbs(String uid, List<String> chatIds,
      {int limit = 40}) async {
    final db = await _db(uid);
    if (db == null || chatIds.isEmpty) return const [];
    final rows = await db.query(
      'messages',
      where: "type = 'image' AND thumb_path IS NULL AND deleted_for_everyone = 0 "
          "AND attachment_url IS NOT NULL AND conversation_id IN "
          "(${List.filled(chatIds.length, '?').join(',')})",
      whereArgs: chatIds,
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((r) => _messageFromRow(r, uid)).toList();
  }

  Future<void> setThumbPath(String uid, String messageId, String path) async {
    final db = await _db(uid);
    if (db == null) return;
    await db.update('messages', {'thumb_path': path}, where: 'id = ?', whereArgs: [messageId]);
  }

  // ── Outbox ─────────────────────────────────────────────────────────────────

  /// Replace [chatId]'s queue with [queue], in order. An empty queue clears it.
  Future<void> replaceOutbox(String uid, String chatId, List<Message> queue) async {
    final db = await _db(uid);
    if (db == null || chatId.isEmpty) return;
    await db.transaction((txn) async {
      await txn.delete('outbox', where: 'conversation_id = ?', whereArgs: [chatId]);
      final batch = txn.batch();
      for (var i = 0; i < queue.length; i++) {
        _putOutbox(batch, chatId, i, queue[i]);
      }
      await batch.commit(noResult: true);
    });
    _emit(uid, ChatChange(outbox: true, threads: {chatId}));
  }

  Future<List<Message>> loadOutbox(String uid, String chatId) async {
    final db = await _db(uid);
    if (db == null || chatId.isEmpty) return const [];
    final rows = await db.query('outbox',
        where: 'conversation_id = ?', whereArgs: [chatId], orderBy: 'position ASC');
    final out = <Message>[];
    for (final r in rows) {
      try {
        out.add(Message.fromJson(
            Map<String, dynamic>.from(jsonDecode(r['payload'] as String) as Map), uid));
      } catch (e) {
        debugPrint('[CHAT_DB] unreadable outbox row skipped: $e');
      }
    }
    return out;
  }

  /// Every chat with something queued.
  Future<List<String>> outboxChatIds(String uid) async {
    final db = await _db(uid);
    if (db == null) return const [];
    final rows = await db.rawQuery('SELECT DISTINCT conversation_id FROM outbox');
    return [for (final r in rows) r['conversation_id'] as String];
  }

  // ── Size, for the report and the logs ──────────────────────────────────────

  Future<Map<String, int>> counts(String uid) async {
    final db = await _db(uid);
    if (db == null) return const {};
    final out = <String, int>{};
    for (final table in ['users', 'conversations', 'messages', 'outbox']) {
      out[table] = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $table')) ?? 0;
    }
    return out;
  }

  // ── Session boundary ───────────────────────────────────────────────────────

  /// Nothing to do synchronously: the sync stops with AppProvider, and the
  /// files go in [purgeOwner], which [SessionScope.endSession] awaits.
  @override
  void resetForSignOut() {}

  /// Sign-out: [uid]'s chat database goes, with its media folder. Sealed
  /// first, so nothing still in flight can re-create it. An unknown owner
  /// (null) means delete every account's chat data.
  @override
  Future<void> purgeOwner(String? uid) async {
    final owner = uid?.trim() ?? '';
    if (owner.isEmpty) {
      await deleteEverything();
      return;
    }
    _sealed.add(owner);
    final open = _open.remove(owner);
    if (open != null) {
      try {
        await (await open).close();
      } catch (_) {}
    }
    final doomed = fileNameFor(owner);
    await _deleteFiles((name) => name == doomed);
    try {
      final dir = Directory('${(await mediaRoot()).path}/${_mediaFolderName(owner)}');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('[CHAT_DB] media purge failed: $e');
    }
    _emit(owner, const ChatChange(all: true));
    debugPrint('[CHAT_DB] chat data of the signed-out account deleted');
  }

  /// Close and delete every chat database and all chat media.
  Future<void> deleteEverything() async {
    final open = Map.of(_open);
    _sealed.addAll(open.keys);
    _open.clear();
    for (final entry in open.entries) {
      try {
        await (await entry.value).close();
      } catch (_) {}
    }
    await _deleteFiles((_) => true);
    try {
      final media = await mediaRoot();
      if (await media.exists()) await media.delete(recursive: true);
    } catch (e) {
      debugPrint('[CHAT_DB] media purge failed: $e');
    }
    _emit('', const ChatChange(all: true));
    debugPrint('[CHAT_DB] all chat data deleted');
  }

  /// Startup hygiene: delete chat databases and media that belong to anyone
  /// but [currentUid] — what an account switch or an interrupted sign-out on
  /// a killed process would otherwise leave behind.
  @override
  Future<void> purgeForeign(String? currentUid) async {
    final current = currentUid?.trim() ?? '';
    // A foreign file still open in this process would keep answering reads
    // after it is unlinked: close and seal it first.
    for (final uid in _open.keys.where((u) => u != current).toList()) {
      _sealed.add(uid);
      final open = _open.remove(uid);
      try {
        await (await open)?.close();
      } catch (_) {}
    }
    final keep = current.isEmpty ? null : fileNameFor(current);
    await _deleteFiles((name) => name != keep);
    try {
      final root = await mediaRoot();
      if (!await root.exists()) return;
      final keepDir = (currentUid == null || currentUid.isEmpty) ? null : _mediaFolderName(currentUid);
      await for (final entity in root.list()) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name != keepDir) await entity.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('[CHAT_DB] foreign media purge failed: $e');
    }
  }

  Future<void> _deleteFiles(bool Function(String fileName) doomed) async {
    try {
      final dir = Directory(await _directory());
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!name.startsWith(_filePrefix)) continue;
        // help24_chat_<uid>.db plus its -wal / -shm / -journal companions.
        final base = name.split('.db').first;
        if (!doomed('$base.db')) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[CHAT_DB] file purge failed: $e');
    }
  }

  // ── Media folders ──────────────────────────────────────────────────────────

  /// Root of every account's chat media (avatars, thumbnails, map snapshots).
  /// App-private (`files/`), never the shared cache Android may clear.
  static Future<Directory> mediaRoot() async {
    final override = directoryOverride;
    final base = override ?? (await getApplicationSupportDirectory()).path;
    return Directory('$base/chat_media');
  }

  static String _mediaFolderName(String uid) =>
      uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// [uid]'s media folder, created on demand.
  static Future<Directory> mediaDirFor(String uid, String kind) async {
    final root = await mediaRoot();
    final dir = Directory('${root.path}/${_mediaFolderName(uid)}/$kind');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Test seam: close every database without deleting anything, so a test can
  /// prove that what was written survives a "restart".
  @visibleForTesting
  Future<void> closeAllForTest() async {
    _sealed.clear();
    final open = Map.of(_open);
    _open.clear();
    for (final f in open.values) {
      try {
        await (await f).close();
      } catch (_) {}
    }
  }
}

/// What a write touched. Listeners re-read only what they show.
class ChatChange {
  const ChatChange({
    this.conversations = false,
    this.people = false,
    this.outbox = false,
    this.threads = const {},
    this.all = false,
    this.owner = '',
  });

  final bool conversations;
  final bool people;
  final bool outbox;
  final Set<String> threads;

  /// Anything may have changed — another isolate wrote the file.
  final bool all;

  bool touchesThread(String chatId) => all || threads.contains(chatId);
  bool get touchesList => all || conversations || people || outbox;

  /// The account whose database was written; '' for a sign-out purge.
  final String owner;

  ChatChange withOwner(String uid) => ChatChange(
        conversations: conversations,
        people: people,
        outbox: outbox,
        threads: threads,
        all: all,
        owner: uid,
      );
}

/// One `chats` row as the server described it, before people are attached.
@immutable
class ChatRowSnapshot {
  const ChatRowSnapshot({
    required this.id,
    required this.participantId,
    required this.lastMessage,
    required this.updatedAt,
    required this.serverUpdatedAt,
    required this.unreadCount,
    this.postId,
    this.postTitle,
  });

  final String id;
  final String participantId;
  final String lastMessage;
  final DateTime updatedAt;

  /// `chats.updated_at` exactly as the server sent it — the sync cursor.
  final String serverUpdatedAt;
  final int unreadCount;
  final String? postId;
  final String? postTitle;
}

/// What thread sync needs to know about one conversation.
@immutable
class ThreadSyncCandidate {
  const ThreadSyncCandidate({
    required this.chatId,
    required this.lastMessageAt,
    required this.threadSyncedAt,
  });

  final String chatId;
  final int lastMessageAt;
  final int? threadSyncedAt;

  /// True when the conversation has moved since its thread was last fetched.
  bool get isStale => threadSyncedAt == null || lastMessageAt > threadSyncedAt!;
}

/// The first 8 characters of an id, for logs — whatever the id's length.
String shortId(String id) => id.length <= 8 ? id : id.substring(0, 8);
