import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Device-local, per-user chat preferences: muted chats, cleared-conversation
/// watermarks and individually hidden ("delete for me") messages.
///
/// Deliberately local-only — none of these concepts exist server-side, and
/// they must never affect the other participant. Everything is keyed in
/// SharedPreferences so it survives restarts and is readable from the FCM
/// background isolate (notification suppression for muted chats).
///
/// Import discipline: dart + shared_preferences only, so the background
/// isolate can use it safely.
class ChatLocalPrefs {
  ChatLocalPrefs._();

  static const _kMutedChats = 'help24_muted_chats';
  static const _kClearedPrefix = 'help24_chat_cleared_';
  static const _kHiddenPrefix = 'help24_chat_hidden_';

  static SharedPreferences? _prefs;
  static Future<SharedPreferences> get _instance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ── Mute ──────────────────────────────────────────────────────────────────

  /// In-memory mirrors for synchronous reads in build methods (tiles, menus).
  /// Populated by [ensureLoaded]; empty until then.
  static Set<String> _mutedCache = {};
  static final Map<String, DateTime> _clearedCache = {};
  static bool _loaded = false;

  /// Loads the muted set and clear-watermarks into memory once per session.
  /// Cheap; call from any screen that needs a synchronous answer.
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await _instance;
    _mutedCache = (prefs.getStringList(_kMutedChats) ?? const []).toSet();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_kClearedPrefix)) continue;
      final raw = prefs.getString(key);
      final parsed = raw != null ? DateTime.tryParse(raw) : null;
      if (parsed != null) {
        _clearedCache[key.substring(_kClearedPrefix.length)] = parsed;
      }
    }
    _loaded = true;
  }

  static bool isMutedSync(String chatId) => _mutedCache.contains(chatId);

  /// Authoritative check — reads storage. Safe from the background isolate.
  /// Reloads from disk so a mute toggled in the foreground isolate is seen.
  static Future<bool> isMuted(String chatId) async {
    if (chatId.isEmpty) return false;
    final prefs = await _instance;
    await prefs.reload();
    return (prefs.getStringList(_kMutedChats) ?? const []).contains(chatId);
  }

  static Future<bool> toggleMuted(String chatId) async {
    final prefs = await _instance;
    await ensureLoaded();
    final muted = _mutedCache.contains(chatId);
    if (muted) {
      _mutedCache.remove(chatId);
    } else {
      _mutedCache.add(chatId);
    }
    await prefs.setStringList(_kMutedChats, _mutedCache.toList());
    return !muted;
  }

  // ── Clear conversation (watermark) ────────────────────────────────────────

  /// Messages at or before this instant are hidden on this device.
  static Future<DateTime?> clearedBefore(String chatId) async {
    if (chatId.isEmpty) return null;
    final prefs = await _instance;
    final raw = prefs.getString('$_kClearedPrefix$chatId');
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Synchronous mirror for list tiles — lets the Messages tab suppress the
  /// last-message preview of a cleared conversation without an async gap.
  static DateTime? clearedBeforeSync(String chatId) => _clearedCache[chatId];

  static Future<void> setClearedBefore(String chatId, DateTime instant) async {
    if (chatId.isEmpty) return;
    final utc = instant.toUtc();
    _clearedCache[chatId] = utc;
    final prefs = await _instance;
    await prefs.setString('$_kClearedPrefix$chatId', utc.toIso8601String());
  }

  // ── Delete for me (hidden message ids) ────────────────────────────────────

  static Future<Set<String>> hiddenMessageIds(String chatId) async {
    if (chatId.isEmpty) return {};
    final prefs = await _instance;
    final raw = prefs.getString('$_kHiddenPrefix$chatId');
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => e.toString()).toSet();
    } catch (_) {
      return {};
    }
  }

  static Future<void> hideMessage(String chatId, String messageId) async {
    if (chatId.isEmpty || messageId.isEmpty) return;
    final prefs = await _instance;
    final ids = await hiddenMessageIds(chatId);
    ids.add(messageId);
    // Cap growth: nobody needs thousands of individually hidden messages.
    final trimmed = ids.length > 500 ? ids.skip(ids.length - 500).toSet() : ids;
    await prefs.setString('$_kHiddenPrefix$chatId', jsonEncode(trimmed.toList()));
  }
}
