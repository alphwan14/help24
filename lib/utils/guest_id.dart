import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Manages guest user identification for non-authenticated users.
/// Generates a unique ID on first use and persists it across app sessions.
class GuestId {
  static const String _guestIdKey = 'help24_guest_id';
  static const String _guestNameKey = 'help24_guest_name';
  static String? _cachedGuestId;
  static String? _cachedGuestName;

  /// Get the current guest ID, creating one if it doesn't exist
  static Future<String> getId() async {
    if (_cachedGuestId != null) {
      return _cachedGuestId!;
    }

    final prefs = await SharedPreferences.getInstance();
    String? guestId = prefs.getString(_guestIdKey);

    if (guestId == null) {
      guestId = const Uuid().v4();
      await prefs.setString(_guestIdKey, guestId);
    }

    _cachedGuestId = guestId;
    return guestId;
  }

  /// Get the guest ID synchronously (only after getId() has been called once)
  static String get currentId => _cachedGuestId ?? '';

  /// Check if guest ID has been initialized
  static bool get isInitialized => _cachedGuestId != null;

  /// Get or set the guest display name
  static Future<String> getName() async {
    if (_cachedGuestName != null) {
      return _cachedGuestName!;
    }

    final prefs = await SharedPreferences.getInstance();
    String? name = prefs.getString(_guestNameKey);

    if (name == null) {
      // Generate a default name
      name = 'Guest ${DateTime.now().millisecondsSinceEpoch % 10000}';
      await prefs.setString(_guestNameKey, name);
    }

    _cachedGuestName = name;
    return name;
  }

  /// Get the current guest name synchronously
  static String get currentName => _cachedGuestName ?? 'Guest';

  /// Update the guest display name
  static Future<void> setName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_guestNameKey, name);
    _cachedGuestName = name;
  }

  /// Initialize guest ID and name at app startup
  static Future<void> initialize() async {
    await getId();
    await getName();
  }

  /// Clear the guest ID (for testing or reset purposes)
  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_guestIdKey);
    await prefs.remove(_guestNameKey);
    _cachedGuestId = null;
    _cachedGuestName = null;
  }

  /// Generate a conversation ID between two users
  static String generateConversationId(String otherUserId) {
    final ids = [currentId, otherUserId]..sort();
    return '${ids[0]}_${ids[1]}';
  }
}
