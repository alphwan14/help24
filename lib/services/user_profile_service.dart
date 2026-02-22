import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../config/firebase_config.dart';
import '../models/user_model.dart';

/// Production user profile: Firestore `users` collection + Firebase Storage for avatar.
/// Document ID = Firebase Auth UID. Use serverTimestamp() for all timestamps.
class UserProfileService {
  static FirebaseFirestore get _firestore => FirebaseFirestore.instance;
  static FirebaseStorage get _storage => FirebaseStorage.instance;

  static const String _collection = 'users';
  static const String _storagePath = 'profiles';

  static bool get _isAvailable => FirebaseConfig.isConfigured;

  /// Create user document on signup. Call after Firebase Auth user is created.
  /// Sets: uid, name, email, phone?, profileImage, bio, createdAt, updatedAt, isOnline=true.
  static Future<void> createUserOnSignup({
    required String uid,
    required String email,
    String? name,
    String? phone,
  }) async {
    if (!_isAvailable) return;
    final ref = _firestore.collection(_collection).doc(uid);
    final existing = await ref.get();
    if (existing.exists) return;

    final displayName = name?.trim() ?? (email.isNotEmpty ? email.split('@').first : '');
    await ref.set({
      'uid': uid,
      'name': displayName,
      'email': email,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      'profileImage': '',
      'bio': '',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'isOnline': true,
      'lastSeen': FieldValue.serverTimestamp(),
    });
    debugPrint('✅ UserProfileService: created user doc $uid');
  }

  /// Ensure profile document exists (e.g. for existing users who signed up before Firestore profiles).
  static Future<void> ensureProfileDoc({
    required String uid,
    required String email,
    String? name,
    String? phone,
  }) async {
    if (!_isAvailable || uid.isEmpty) return;
    final ref = _firestore.collection(_collection).doc(uid);
    final existing = await ref.get();
    if (existing.exists) return;
    final displayName = name?.trim() ?? (email.isNotEmpty ? email.split('@').first : '');
    await ref.set({
      'uid': uid,
      'name': displayName,
      'email': email,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      'profileImage': '',
      'bio': '',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'isOnline': true,
      'lastSeen': FieldValue.serverTimestamp(),
    });
    debugPrint('✅ UserProfileService: ensured user doc $uid');
  }

  /// Call on login: set isOnline = true, lastSeen = now.
  static Future<void> setOnline(String uid, bool isOnline) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _firestore.collection(_collection).doc(uid).set({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('UserProfileService setOnline: $e');
    }
  }

  /// Real-time stream of user profile. Use in StreamBuilder.
  static Stream<UserModel?> watchUser(String? uid) {
    if (!_isAvailable || uid == null || uid.isEmpty) return Stream.value(null);
    return _firestore.collection(_collection).doc(uid).snapshots().map((snap) {
      if (!snap.exists || snap.data() == null) return null;
      return UserModel.fromFirestore(snap);
    });
  }

  /// One-time fetch (e.g. for chat display name/avatar).
  static Future<UserModel?> getUser(String? uid) async {
    if (!_isAvailable || uid == null || uid.isEmpty) return null;
    try {
      final snap = await _firestore.collection(_collection).doc(uid).get();
      if (!snap.exists || snap.data() == null) return null;
      return UserModel.fromFirestore(snap);
    } catch (e) {
      debugPrint('UserProfileService getUser: $e');
      return null;
    }
  }

  /// Update profile fields. updatedAt set to server timestamp.
  static Future<void> updateProfile({
    required String uid,
    String? name,
    String? bio,
    String? profileImage,
  }) async {
    if (!_isAvailable || uid.isEmpty) return;
    final updates = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (name != null) updates['name'] = name;
    if (bio != null) updates['bio'] = bio;
    if (profileImage != null) updates['profileImage'] = profileImage;
    await _firestore.collection(_collection).doc(uid).set(updates, SetOptions(merge: true));
  }

  /// Upload profile image to Firebase Storage, return download URL.
  /// Path: profiles/{uid}.{ext}
  static Future<String> uploadProfileImage(XFile file, String uid) async {
    if (!_isAvailable) throw UserProfileException('Firebase is not configured.');
    final bytes = await file.readAsBytes();
    if (bytes.length > 5 * 1024 * 1024) throw UserProfileException('Image too large. Max 5MB.');
    final ext = _extensionFromXFile(file);
    final path = '$_storagePath/$uid.$ext';
    final ref = _storage.ref().child(path);
    // Web: uploadBytes; mobile: can use putFile if we had File path. Use uploadBytes for cross-platform.
    final metadata = SettableMetadata(contentType: _contentType(ext));
    await ref.putData(bytes, metadata);
    final url = await ref.getDownloadURL();
    return url;
  }

  static String _extensionFromXFile(XFile file) {
    final mime = file.mimeType?.toLowerCase() ?? '';
    if (mime.contains('png')) return 'png';
    if (mime.contains('gif')) return 'gif';
    if (mime.contains('webp')) return 'webp';
    final name = file.name.toLowerCase();
    if (name.endsWith('.png')) return 'png';
    if (name.endsWith('.gif')) return 'gif';
    if (name.endsWith('.webp')) return 'webp';
    return 'jpg';
  }

  static String _contentType(String ext) {
    switch (ext.toLowerCase()) {
      case 'png': return 'image/png';
      case 'gif': return 'image/gif';
      case 'webp': return 'image/webp';
      default: return 'image/jpeg';
    }
  }

  // ---------- User preferences (Firestore merge only; no UserModel changes) ----------

  /// Notifications: users/{uid}.fcmTokens (array), users/{uid}.notificationsEnabled (bool).
  static Future<void> setNotificationsEnabled(String uid, bool enabled) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _firestore.collection(_collection).doc(uid).set({
        'notificationsEnabled': enabled,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      // When disabling, caller (NotificationService) should remove current FCM token from fcmTokens.
    } catch (e) {
      debugPrint('UserProfileService setNotificationsEnabled: $e');
    }
  }

  /// Add FCM token to users/{uid}.fcmTokens (array). Only call when notificationsEnabled is true.
  static Future<void> addFcmToken(String uid, String token) async {
    if (!_isAvailable || uid.isEmpty || token.isEmpty) return;
    try {
      await _firestore.collection(_collection).doc(uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('UserProfileService addFcmToken: $e');
    }
  }

  /// Remove FCM token from users/{uid}.fcmTokens.
  static Future<void> removeFcmToken(String uid, String token) async {
    if (!_isAvailable || uid.isEmpty || token.isEmpty) return;
    try {
      await _firestore.collection(_collection).doc(uid).update({
        'fcmTokens': FieldValue.arrayRemove([token]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('UserProfileService removeFcmToken: $e');
    }
  }

  /// Get notificationsEnabled and fcmTokens for a user (one-time read).
  static Future<({bool notificationsEnabled, List<String> fcmTokens})> getNotificationPrefs(String uid) async {
    if (!_isAvailable || uid.isEmpty) return (notificationsEnabled: true, fcmTokens: <String>[]);
    try {
      final snap = await _firestore.collection(_collection).doc(uid).get();
      final data = snap.data();
      if (data == null) return (notificationsEnabled: true, fcmTokens: <String>[]);
      final list = data['fcmTokens'];
      final tokens = list is List ? list.map((e) => e.toString()).where((s) => s.isNotEmpty).toList() : <String>[];
      final enabled = data['notificationsEnabled'] as bool? ?? true;
      return (notificationsEnabled: enabled, fcmTokens: tokens);
    } catch (e) {
      debugPrint('UserProfileService getNotificationPrefs: $e');
      return (notificationsEnabled: true, fcmTokens: <String>[]);
    }
  }

  /// Language: users/{uid}.language ("en" | "sw").
  static Future<void> setLanguage(String uid, String languageCode) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _firestore.collection(_collection).doc(uid).set({
        'language': languageCode,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('UserProfileService setLanguage: $e');
    }
  }

  /// Get language for user (one-time). Returns "en" or "sw".
  static Future<String> getLanguage(String uid) async {
    if (!_isAvailable || uid.isEmpty) return 'en';
    try {
      final snap = await _firestore.collection(_collection).doc(uid).get();
      final code = snap.data()?['language']?.toString();
      if (code == 'sw') return 'sw';
      if (code == 'en') return 'en';
      return 'en';
    } catch (e) {
      return 'en';
    }
  }

  /// Record TOS acceptance: users/{uid}.tosAcceptedAt (server timestamp).
  static Future<void> setTosAccepted(String uid) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _firestore.collection(_collection).doc(uid).set({
        'tosAcceptedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('UserProfileService setTosAccepted: $e');
    }
  }

  /// Real-time stream of user preferences only (notificationsEnabled, language). Does not modify UserModel.
  static Stream<({bool notificationsEnabled, String language})> watchUserPrefs(String? uid) {
    if (!_isAvailable || uid == null || uid.isEmpty) {
      return Stream.value((notificationsEnabled: true, language: 'en'));
    }
    return _firestore.collection(_collection).doc(uid).snapshots().map((snap) {
      final data = snap.data();
      final enabled = data?['notificationsEnabled'] as bool? ?? true;
      final lang = data?['language']?.toString();
      final language = (lang == 'sw' || lang == 'en') ? lang! : 'en';
      return (notificationsEnabled: enabled, language: language);
    });
  }
}

class UserProfileException implements Exception {
  final String message;
  UserProfileException(this.message);
  @override
  String toString() => 'UserProfileException: $message';
}
