import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/user_model.dart';
import 'storage_service.dart';

/// User profile: Supabase `users` table + Supabase Storage bucket `profiles` for avatar.
/// No Firestore or Firebase Storage. id = Firebase Auth UID (synced to Supabase on login).
class UserProfileService {
  static SupabaseClient get _client => SupabaseConfig.client;

  static bool get _isAvailable => SupabaseConfig.isInitialized;

  /// Create or ensure user row in Supabase on signup. Call after Firebase Auth user is created.
  static Future<void> createUserOnSignup({
    required String uid,
    required String email,
    String? name,
    String? phone,
  }) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      final displayName = name?.trim() ?? (email.isNotEmpty ? email.split('@').first : '');
      await _client.from('users').upsert({
        'id': uid,
        'email': email,
        'name': displayName,
        if (phone != null && phone.isNotEmpty) 'phone_number': phone,
        'profile_image': '',
      }, onConflict: 'id');
      debugPrint('✅ UserProfileService: created/updated user $uid in Supabase');
    } catch (e) {
      debugPrint('UserProfileService createUserOnSignup: $e');
      rethrow;
    }
  }

  /// Ensure profile row exists in Supabase (e.g. for existing users).
  static Future<void> ensureProfileDoc({
    required String uid,
    required String email,
    String? name,
    String? phone,
  }) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      final existing = await _client.from('users').select('id').eq('id', uid).maybeSingle();
      if (existing != null) return;
      final displayName = name?.trim() ?? (email.isNotEmpty ? email.split('@').first : '');
      await _client.from('users').insert({
        'id': uid,
        'email': email,
        'name': displayName,
        if (phone != null && phone.isNotEmpty) 'phone_number': phone,
        'profile_image': '',
      });
      debugPrint('UserProfileService: ensured user $uid in Supabase');
    } catch (e) {
      debugPrint('UserProfileService ensureProfileDoc ($uid): $e');
      rethrow;
    }
  }

  /// Set online status and last_seen in Supabase users.
  static Future<void> setOnline(String uid, bool isOnline) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _client.from('users').update({
        'is_online': isOnline,
        'last_seen': DateTime.now().toIso8601String(),
      }).eq('id', uid);
    } catch (e) {
      debugPrint('UserProfileService setOnline: $e');
    }
  }

  /// Stream of user profile from Supabase (polling every 15s, no Realtime).
  static Stream<UserModel?> watchUser(String? uid) {
    if (!_isAvailable || uid == null || uid.isEmpty) return Stream.value(null);

    final controller = StreamController<UserModel?>.broadcast();
    Timer? timer;

    Future<void> fetch() async {
      try {
        final r = await _client.from('users').select().eq('id', uid).maybeSingle();
        if (controller.isClosed) return;
        if (r != null) {
          controller.add(UserModel.fromSupabase(r as Map<String, dynamic>));
        } else {
          controller.add(null);
        }
      } catch (e) {
        debugPrint('UserProfileService watchUser fetch: $e');
        if (!controller.isClosed) controller.add(null);
      }
    }

    fetch();
    timer = Timer.periodic(const Duration(seconds: 15), (_) => fetch());
    controller.onCancel = () => timer?.cancel();

    return controller.stream;
  }

  /// One-time fetch from Supabase users.
  static Future<UserModel?> getUser(String? uid) async {
    if (!_isAvailable || uid == null || uid.isEmpty) return null;
    try {
      final r = await _client.from('users').select().eq('id', uid).maybeSingle();
      if (r != null) return UserModel.fromSupabase(r as Map<String, dynamic>);
      return null;
    } catch (e) {
      debugPrint('UserProfileService getUser ($uid): $e');
      return null;
    }
  }

  /// Update profile in Supabase users. Saves profile_image URL (from Supabase Storage).
  static Future<void> updateProfile({
    required String uid,
    String? name,
    String? bio,
    String? profileImage,
  }) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      final updates = <String, dynamic>{};
      if (name != null) updates['name'] = name;
      if (bio != null) updates['bio'] = bio;
      if (profileImage != null) {
        updates['profile_image'] = profileImage;
        updates['avatar_url'] = profileImage;
      }
      if (updates.isEmpty) return;
      await _client.from('users').update(updates).eq('id', uid);
    } catch (e) {
      debugPrint('UserProfileService updateProfile ($uid): $e');
      rethrow;
    }
  }

  /// Upload profile image to Supabase Storage bucket `profiles`, save URL to users.profile_image, return public URL.
  /// On failure throws (do NOT show success). Caller should catch and show error.
  static Future<String> uploadProfileImage(XFile file, String uid) async {
    if (!_isAvailable) {
      debugPrint('UserProfileService.uploadProfileImage: Supabase not configured');
      throw UserProfileException('Profile upload is not available.');
    }
    try {
      final url = await StorageService.uploadProfileImageToProfilesBucket(file, uid);
      if (url.isEmpty) throw UserProfileException('Upload returned no URL.');
      final t = DateTime.now().millisecondsSinceEpoch;
      final urlWithCacheBuster = url.contains('?') ? '$url&t=$t' : '$url?t=$t';
      await _client.from('users').update({
        'profile_image': urlWithCacheBuster,
        'avatar_url': urlWithCacheBuster,
      }).eq('id', uid);
      debugPrint('UserProfileService.uploadProfileImage: saved URL to users.profile_image');
      return urlWithCacheBuster;
    } catch (e) {
      debugPrint('UserProfileService.uploadProfileImage FAILED: $e');
      rethrow;
    }
  }

  // ---------- User preferences (Supabase users table) ----------

  static Future<void> setNotificationsEnabled(String uid, bool enabled) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _client.from('users').update({'notifications_enabled': enabled}).eq('id', uid);
    } catch (e) {
      debugPrint('UserProfileService setNotificationsEnabled: $e');
    }
  }

  static Future<void> addFcmToken(String uid, String token) async {
    if (!_isAvailable || uid.isEmpty || token.isEmpty) return;
    try {
      final r = await _client.from('users').select('fcm_tokens').eq('id', uid).maybeSingle();
      final list = <dynamic>[];
      if (r != null && r['fcm_tokens'] != null) {
        final current = r['fcm_tokens'];
        if (current is List) list.addAll(current.map((e) => e.toString()));
      }
      if (!list.contains(token)) list.add(token);
      await _client.from('users').update({'fcm_tokens': list}).eq('id', uid);
    } catch (e) {
      debugPrint('UserProfileService addFcmToken: $e');
    }
  }

  static Future<void> removeFcmToken(String uid, String token) async {
    if (!_isAvailable || uid.isEmpty || token.isEmpty) return;
    try {
      final r = await _client.from('users').select('fcm_tokens').eq('id', uid).maybeSingle();
      final list = <String>[];
      if (r != null && r['fcm_tokens'] != null) {
        final current = r['fcm_tokens'];
        if (current is List) {
          for (final e in current) {
            final s = e.toString();
            if (s != token) list.add(s);
          }
        }
      }
      await _client.from('users').update({'fcm_tokens': list}).eq('id', uid);
    } catch (e) {
      debugPrint('UserProfileService removeFcmToken: $e');
    }
  }

  static Future<({bool notificationsEnabled, List<String> fcmTokens})> getNotificationPrefs(String uid) async {
    if (!_isAvailable || uid.isEmpty) return (notificationsEnabled: true, fcmTokens: <String>[]);
    try {
      final r = await _client.from('users').select('notifications_enabled, fcm_tokens').eq('id', uid).maybeSingle();
      if (r == null) return (notificationsEnabled: true, fcmTokens: <String>[]);
      final list = r['fcm_tokens'];
      final tokens = list is List ? list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList() : <String>[];
      final enabled = r['notifications_enabled'] as bool? ?? true;
      return (notificationsEnabled: enabled, fcmTokens: tokens);
    } catch (e) {
      debugPrint('UserProfileService getNotificationPrefs: $e');
      return (notificationsEnabled: true, fcmTokens: <String>[]);
    }
  }

  static Future<void> setLanguage(String uid, String languageCode) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _client.from('users').update({'language': languageCode}).eq('id', uid);
    } catch (e) {
      debugPrint('UserProfileService setLanguage: $e');
    }
  }

  static Future<String> getLanguage(String uid) async {
    if (!_isAvailable || uid.isEmpty) return 'en';
    try {
      final r = await _client.from('users').select('language').eq('id', uid).maybeSingle();
      final code = r?['language']?.toString();
      if (code == 'sw') return 'sw';
      if (code == 'en') return 'en';
      return 'en';
    } catch (e) {
      return 'en';
    }
  }

  static Future<void> setTosAccepted(String uid) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _client.from('users').update({
        'tos_accepted_at': DateTime.now().toIso8601String(),
      }).eq('id', uid);
    } catch (e) {
      debugPrint('UserProfileService setTosAccepted: $e');
    }
  }

  /// Stream of user prefs (polling every 15s, no Realtime).
  static Stream<({bool notificationsEnabled, String language})> watchUserPrefs(String? uid) {
    if (!_isAvailable || uid == null || uid.isEmpty) {
      return Stream.value((notificationsEnabled: true, language: 'en'));
    }
    final controller = StreamController<({bool notificationsEnabled, String language})>.broadcast();
    Timer? timer;

    Future<void> fetch() async {
      try {
        final r = await _client.from('users').select('notifications_enabled, language').eq('id', uid).maybeSingle();
        if (controller.isClosed) return;
        final enabled = r?['notifications_enabled'] as bool? ?? true;
        final lang = r?['language']?.toString();
        final language = (lang == 'sw' || lang == 'en') ? lang! : 'en';
        controller.add((notificationsEnabled: enabled, language: language));
      } catch (e) {
        if (!controller.isClosed) controller.add((notificationsEnabled: true, language: 'en'));
      }
    }

    fetch();
    timer = Timer.periodic(const Duration(seconds: 15), (_) => fetch());
    controller.onCancel = () => timer?.cancel();
    return controller.stream;
  }
}

class UserProfileException implements Exception {
  final String message;
  UserProfileException(this.message);
  @override
  String toString() => 'UserProfileException: $message';
}
