import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../config/firebase_config.dart';
import '../config/supabase_config.dart';

/// User model for the app (messaging-ready: userId, name, phone, email, profileImage).
class AppUser {
  final String id;
  final String email;
  final String? name;
  final String? phoneNumber;
  final String? photoUrl;
  final DateTime createdAt;
  final DateTime lastLogin;

  AppUser({
    required this.id,
    required this.email,
    this.name,
    this.phoneNumber,
    this.photoUrl,
    required this.createdAt,
    required this.lastLogin,
  });

  /// For messaging and display
  String get userId => id;
  String? get profileImage => photoUrl;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      email: json['email'] as String? ?? '',
      name: json['name'] as String?,
      phoneNumber: json['phone_number'] as String?,
      photoUrl: json['profile_image'] as String? ?? json['photo_url'] as String?,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now(),
      lastLogin: DateTime.tryParse(json['last_login']?.toString() ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'name': name,
      'phone_number': phoneNumber,
      'photo_url': photoUrl,
      'created_at': createdAt.toIso8601String(),
      'last_login': lastLogin.toIso8601String(),
    };
  }

  AppUser copyWith({
    String? id,
    String? email,
    String? name,
    String? phoneNumber,
    String? photoUrl,
    DateTime? createdAt,
    DateTime? lastLogin,
  }) {
    return AppUser(
      id: id ?? this.id,
      email: email ?? this.email,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      photoUrl: photoUrl ?? this.photoUrl,
      createdAt: createdAt ?? this.createdAt,
      lastLogin: lastLogin ?? this.lastLogin,
    );
  }

  String get displayName => (name != null && name!.trim().isNotEmpty) ? name! : (email.isNotEmpty ? email.split('@').first : (phoneNumber ?? 'User'));
  bool get hasProfile => name != null && name!.trim().isNotEmpty;

  String get initials {
    if (name != null && name!.isNotEmpty) {
      final parts = name!.split(' ');
      if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      return name![0].toUpperCase();
    }
    if (email.isNotEmpty) return email[0].toUpperCase();
    if (phoneNumber != null && phoneNumber!.length >= 2) return phoneNumber!.substring(phoneNumber!.length - 2);
    return '?';
  }
}

class AuthResult {
  final bool success;
  final String? errorMessage;
  final AppUser? user;

  AuthResult.success(this.user) : success = true, errorMessage = null;
  AuthResult.failure(this.errorMessage) : success = false, user = null;
}

/// Phone verification state (held by AuthProvider after sendOtp).
class PhoneVerificationState {
  final String verificationId;
  final int? resendToken;

  PhoneVerificationState({required this.verificationId, this.resendToken});
}

/// Authentication service: Firebase (phone OTP + email) + Supabase user sync.
class AuthService {
  static final _supabase = SupabaseConfig.client;

  static bool get isFirebaseConfigured => FirebaseConfig.isConfigured;

  static FirebaseAuth? get _firebaseAuth {
    if (!isFirebaseConfigured) return null;
    try {
      return FirebaseAuth.instance;
    } catch (e) {
      debugPrint('Firebase not initialized: $e');
      return null;
    }
  }

  static User? get currentFirebaseUser {
    try {
      return _firebaseAuth?.currentUser;
    } catch (e) {
      debugPrint('Error getting current user: $e');
      return null;
    }
  }

  static bool get isLoggedIn => currentFirebaseUser != null;
  static String? get currentUserId => currentFirebaseUser?.uid;

  // ---------- Phone (OTP) ----------

  /// Start phone verification. Callbacks are invoked from platform code.
  static Future<void> verifyPhoneNumber({
    required String phoneNumber,
    required void Function(String verificationId, int? resendToken) codeSent,
    required void Function(FirebaseAuthException e) verificationFailed,
    void Function(PhoneAuthCredential credential)? verificationCompleted,
    void Function(String verificationId)? codeAutoRetrievalTimeout,
  }) async {
    if (!isFirebaseConfigured) {
      verificationFailed(FirebaseAuthException(
        code: 'not-configured',
        message: 'Authentication is not configured.',
      ));
      return;
    }
    final auth = _firebaseAuth!;
    final normalized = _normalizePhone(phoneNumber);
    try {
      await auth.verifyPhoneNumber(
        phoneNumber: normalized,
        verificationCompleted: verificationCompleted ?? (_) {},
        verificationFailed: verificationFailed,
        codeSent: codeSent,
        codeAutoRetrievalTimeout: codeAutoRetrievalTimeout ?? (_) {},
        timeout: const Duration(seconds: 120),
      );
    } catch (e) {
      verificationFailed(FirebaseAuthException(
        code: 'unknown',
        message: e.toString(),
      ));
    }
  }

  static String _normalizePhone(String phone) {
    String s = phone.replaceAll(RegExp(r'\s'), '');
    if (!s.startsWith('+')) {
      if (s.startsWith('0')) s = '+254${s.substring(1)}';
      else if (s.length <= 9) s = '+254$s';
      else s = '+$s';
    }
    return s;
  }

  /// Verify OTP and sign in. Returns success with user or failure with message.
  static Future<AuthResult> verifyOtp({
    required String verificationId,
    required String smsCode,
  }) async {
    if (!isFirebaseConfigured) {
      return AuthResult.failure('Authentication is not configured.');
    }
    final auth = _firebaseAuth!;
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      );
      final result = await auth.signInWithCredential(credential);
      final user = result.user;
      if (user == null) return AuthResult.failure('Sign in failed. Please try again.');
      final isNew = result.additionalUserInfo?.isNewUser ?? false;
      final phone = user.phoneNumber ?? _normalizePhone(user.uid);
      final appUser = await _syncUserToSupabase(
        user,
        name: user.displayName,
        phoneNumber: phone,
      );
      if (isNew && (appUser.name == null || appUser.name!.trim().isEmpty)) {
        // New phone user: keep appUser but caller should show profile setup
      }
      debugPrint('✅ Phone sign in: ${appUser.id}');
      return AuthResult.success(appUser);
    } on FirebaseAuthException catch (e) {
      return AuthResult.failure(getPhoneErrorMessage(e));
    } catch (e) {
      debugPrint('❌ verifyOtp: $e');
      return AuthResult.failure('Something went wrong. Please try again.');
    }
  }

  static String getPhoneErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-verification-code':
        return 'Invalid or expired code. Please check and try again.';
      case 'session-expired':
        return 'Verification expired. Please request a new code.';
      case 'invalid-verification-id':
        return 'Session expired. Please start again from your phone number.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'invalid-phone-number':
        return 'Please enter a valid phone number (e.g. +254 7XX XXX XXX).';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      default:
        return e.message ?? 'Verification failed. Please try again.';
    }
  }

  // ---------- Email ----------

  static Future<AuthResult> signUp({
    required String email,
    required String password,
    String? name,
  }) async {
    if (!isFirebaseConfigured) {
      return AuthResult.failure('Authentication is not configured. Please add Firebase credentials.');
    }
    final auth = _firebaseAuth;
    if (auth == null) return AuthResult.failure('Firebase is not initialized.');
    try {
      final credential = await auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final firebaseUser = credential.user;
      if (firebaseUser == null) return AuthResult.failure('Failed to create account. Please try again.');
      if (name != null && name.trim().isNotEmpty) {
        await firebaseUser.updateDisplayName(name.trim());
        await firebaseUser.reload();
      }
      final appUser = await _syncUserToSupabase(auth.currentUser ?? firebaseUser, name: name?.trim());
      debugPrint('✅ User signed up: ${appUser.email}');
      return AuthResult.success(appUser);
    } on FirebaseAuthException catch (e) {
      return AuthResult.failure(_getFirebaseErrorMessage(e));
    } catch (e) {
      debugPrint('❌ Sign up error: $e');
      return AuthResult.failure('An unexpected error occurred. Please try again.');
    }
  }

  static Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    if (!isFirebaseConfigured) {
      return AuthResult.failure('Authentication is not configured. Please add Firebase credentials.');
    }
    final auth = _firebaseAuth;
    if (auth == null) return AuthResult.failure('Firebase is not initialized.');
    try {
      final credential = await auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      final firebaseUser = credential.user;
      if (firebaseUser == null) return AuthResult.failure('Failed to sign in. Please try again.');
      final appUser = await _syncUserToSupabase(firebaseUser);
      debugPrint('✅ User signed in: ${appUser.email}');
      return AuthResult.success(appUser);
    } on FirebaseAuthException catch (e) {
      return AuthResult.failure(_getFirebaseErrorMessage(e));
    } catch (e) {
      debugPrint('❌ Sign in error: $e');
      return AuthResult.failure('An unexpected error occurred. Check your connection.');
    }
  }

  static Future<void> signOut() async {
    try {
      await _firebaseAuth?.signOut();
      debugPrint('✅ User signed out');
    } catch (e) {
      debugPrint('❌ Sign out error: $e');
    }
  }

  static Future<AuthResult> sendPasswordResetEmail(String email) async {
    if (!isFirebaseConfigured) return AuthResult.failure('Authentication is not configured.');
    final auth = _firebaseAuth;
    if (auth == null) return AuthResult.failure('Firebase is not initialized.');
    try {
      await auth.sendPasswordResetEmail(email: email.trim());
      debugPrint('✅ Password reset email sent to: $email');
      return AuthResult.success(null);
    } on FirebaseAuthException catch (e) {
      return AuthResult.failure(_getFirebaseErrorMessage(e));
    } catch (e) {
      debugPrint('❌ Password reset error: $e');
      return AuthResult.failure('Failed to send reset email. Please try again.');
    }
  }

  static Future<AppUser?> getCurrentAppUser() async {
    final firebaseUser = currentFirebaseUser;
    if (firebaseUser == null) return null;
    try {
      return await _syncUserToSupabase(
        firebaseUser,
        phoneNumber: firebaseUser.phoneNumber,
      );
    } catch (e) {
      debugPrint('Error getting current user: $e');
      return AppUser(
        id: firebaseUser.uid,
        email: firebaseUser.email ?? '',
        name: firebaseUser.displayName,
        phoneNumber: firebaseUser.phoneNumber,
        photoUrl: firebaseUser.photoURL,
        createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
        lastLogin: DateTime.now(),
      );
    }
  }

  static Future<AuthResult> updateProfile({
    String? name,
    String? photoUrl,
  }) async {
    final firebaseUser = currentFirebaseUser;
    if (firebaseUser == null) return AuthResult.failure('Not logged in.');
    try {
      if (name != null && name.trim().isNotEmpty) await firebaseUser.updateDisplayName(name.trim());
      if (photoUrl != null) await firebaseUser.updatePhotoURL(photoUrl);
      await firebaseUser.reload();
      final updates = <String, dynamic>{'last_login': DateTime.now().toIso8601String()};
      if (name != null) updates['name'] = name.trim();
      if (photoUrl != null) updates['profile_image'] = photoUrl;
      await _supabase.from('users').update(updates).eq('id', firebaseUser.uid);
      final updatedUser = await getCurrentAppUser();
      return AuthResult.success(updatedUser);
    } catch (e) {
      debugPrint('Update profile error: $e');
      return AuthResult.failure('Failed to update profile.');
    }
  }

  /// Sync Firebase user to Supabase users table (no RPC).
  /// Uses client-side upsert: id = Firebase UID, no duplicates.
  static Future<AppUser> _syncUserToSupabase(
    User firebaseUser, {
    String? name,
    String? phoneNumber,
  }) async {
    final now = DateTime.now();
    final userName = name ??
        firebaseUser.displayName ??
        firebaseUser.email?.split('@').first ??
        (firebaseUser.phoneNumber != null ? 'User' : '');
    final phone = firebaseUser.phoneNumber ?? phoneNumber;
    final email = firebaseUser.email ?? '';
    final profileImage = firebaseUser.photoURL;

    final row = <String, dynamic>{
      'id': firebaseUser.uid,
      'phone_number': phone,
      'email': email,
      'name': userName,
      'profile_image': profileImage,
      'last_login': now.toIso8601String(),
      // Do NOT send created_at: DB default handles new rows; existing rows keep their created_at
    };

    try {
      await _supabase.from('users').upsert(
        row,
        onConflict: 'id',
      );
      final inserted = await _supabase.from('users').select().eq('id', firebaseUser.uid).maybeSingle();
      if (inserted != null) {
        debugPrint('✅ User synced to Supabase: ${firebaseUser.uid}');
        return AppUser.fromJson(inserted as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('❌ Supabase sync: $e');
    }

    return AppUser(
      id: firebaseUser.uid,
      email: email,
      name: userName.isEmpty ? null : userName,
      phoneNumber: phone,
      photoUrl: profileImage,
      createdAt: now,
      lastLogin: now,
    );
  }

  static String _getFirebaseErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return 'This email is already registered. Try signing in instead.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'operation-not-allowed':
        return 'Email sign in is not enabled.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'user-disabled':
        return 'This account has been disabled. Contact support.';
      case 'user-not-found':
        return 'No account found with this email. Sign up instead?';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-credential':
        return 'Invalid email or password. Please check and try again.';
      case 'too-many-requests':
        return 'Too many attempts. Try again in a few minutes.';
      case 'network-request-failed':
        return 'Network error. Check your internet connection.';
      case 'requires-recent-login':
        return 'Please sign in again to continue.';
      default:
        return e.message ?? 'Something went wrong. Please try again.';
    }
  }

  static Stream<User?> get authStateChanges {
    if (!isFirebaseConfigured) return const Stream.empty();
    try {
      return FirebaseAuth.instance.authStateChanges();
    } catch (e) {
      return const Stream.empty();
    }
  }

  static bool isValidEmail(String email) {
    return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);
  }

  static String? validatePassword(String password) {
    if (password.isEmpty) return 'Password is required';
    if (password.length < 6) return 'Password must be at least 6 characters';
    return null;
  }
}
