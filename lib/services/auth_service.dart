import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../config/firebase_config.dart';
import '../config/supabase_config.dart';

/// User model for the app
class AppUser {
  final String id; // Firebase UID
  final String email;
  final String? name;
  final String? photoUrl;
  final DateTime createdAt;
  final DateTime lastLogin;

  AppUser({
    required this.id,
    required this.email,
    this.name,
    this.photoUrl,
    required this.createdAt,
    required this.lastLogin,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      email: json['email'] as String,
      name: json['name'] as String?,
      photoUrl: json['photo_url'] as String?,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ?? DateTime.now(),
      lastLogin: DateTime.tryParse(json['last_login']?.toString() ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'name': name,
      'photo_url': photoUrl,
      'created_at': createdAt.toIso8601String(),
      'last_login': lastLogin.toIso8601String(),
    };
  }

  AppUser copyWith({
    String? id,
    String? email,
    String? name,
    String? photoUrl,
    DateTime? createdAt,
    DateTime? lastLogin,
  }) {
    return AppUser(
      id: id ?? this.id,
      email: email ?? this.email,
      name: name ?? this.name,
      photoUrl: photoUrl ?? this.photoUrl,
      createdAt: createdAt ?? this.createdAt,
      lastLogin: lastLogin ?? this.lastLogin,
    );
  }
  
  /// Get display name or fallback
  String get displayName => name ?? email.split('@').first;
  
  /// Get initials for avatar
  String get initials {
    if (name != null && name!.isNotEmpty) {
      final parts = name!.split(' ');
      if (parts.length >= 2) {
        return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      }
      return name![0].toUpperCase();
    }
    return email[0].toUpperCase();
  }
}

/// Result of an auth operation
class AuthResult {
  final bool success;
  final String? errorMessage;
  final AppUser? user;

  AuthResult.success(this.user)
      : success = true,
        errorMessage = null;

  AuthResult.failure(this.errorMessage)
      : success = false,
        user = null;
}

/// Service for handling authentication with Firebase and Supabase user sync
class AuthService {
  static final _supabase = SupabaseConfig.client;
  
  /// Check if Firebase is available
  static bool get isFirebaseConfigured => FirebaseConfig.isConfigured;
  
  /// Get FirebaseAuth instance safely
  static FirebaseAuth? get _firebaseAuth {
    if (!isFirebaseConfigured) return null;
    try {
      return FirebaseAuth.instance;
    } catch (e) {
      debugPrint('Firebase not initialized: $e');
      return null;
    }
  }
  
  /// Get current Firebase user
  static User? get currentFirebaseUser {
    try {
      return _firebaseAuth?.currentUser;
    } catch (e) {
      debugPrint('Error getting current user: $e');
      return null;
    }
  }
  
  /// Check if user is logged in
  static bool get isLoggedIn => currentFirebaseUser != null;
  
  /// Get current user ID
  static String? get currentUserId => currentFirebaseUser?.uid;
  
  /// Sign up with email and password
  static Future<AuthResult> signUp({
    required String email,
    required String password,
    String? name,
  }) async {
    if (!isFirebaseConfigured) {
      return AuthResult.failure('Authentication is not configured. Please add Firebase credentials.');
    }
    
    final auth = _firebaseAuth;
    if (auth == null) {
      return AuthResult.failure('Firebase is not initialized');
    }
    
    try {
      // Create Firebase user
      final credential = await auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      
      final firebaseUser = credential.user;
      if (firebaseUser == null) {
        return AuthResult.failure('Failed to create account. Please try again.');
      }
      
      // Update display name if provided
      if (name != null && name.trim().isNotEmpty) {
        await firebaseUser.updateDisplayName(name.trim());
        // Reload to get updated user
        await firebaseUser.reload();
      }
      
      // Create user in Supabase
      final appUser = await _syncUserToSupabase(
        auth.currentUser ?? firebaseUser,
        name: name?.trim(),
      );
      
      debugPrint('✅ User signed up: ${appUser.email}');
      return AuthResult.success(appUser);
      
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ Sign up error: ${e.code} - ${e.message}');
      return AuthResult.failure(_getFirebaseErrorMessage(e));
    } catch (e) {
      debugPrint('❌ Sign up error: $e');
      return AuthResult.failure('An unexpected error occurred. Please try again.');
    }
  }
  
  /// Sign in with email and password
  static Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    if (!isFirebaseConfigured) {
      return AuthResult.failure('Authentication is not configured. Please add Firebase credentials.');
    }
    
    final auth = _firebaseAuth;
    if (auth == null) {
      return AuthResult.failure('Firebase is not initialized');
    }
    
    try {
      // Sign in with Firebase
      final credential = await auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      
      final firebaseUser = credential.user;
      if (firebaseUser == null) {
        return AuthResult.failure('Failed to sign in. Please try again.');
      }
      
      // Sync/create user in Supabase
      final appUser = await _syncUserToSupabase(firebaseUser);
      
      debugPrint('✅ User signed in: ${appUser.email}');
      return AuthResult.success(appUser);
      
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ Sign in error: ${e.code} - ${e.message}');
      return AuthResult.failure(_getFirebaseErrorMessage(e));
    } catch (e) {
      debugPrint('❌ Sign in error: $e');
      return AuthResult.failure('An unexpected error occurred. Please check your connection.');
    }
  }
  
  /// Sign out
  static Future<void> signOut() async {
    try {
      await _firebaseAuth?.signOut();
      debugPrint('✅ User signed out');
    } catch (e) {
      debugPrint('❌ Sign out error: $e');
    }
  }
  
  /// Send password reset email
  static Future<AuthResult> sendPasswordResetEmail(String email) async {
    if (!isFirebaseConfigured) {
      return AuthResult.failure('Authentication is not configured');
    }
    
    final auth = _firebaseAuth;
    if (auth == null) {
      return AuthResult.failure('Firebase is not initialized');
    }
    
    try {
      await auth.sendPasswordResetEmail(email: email.trim());
      debugPrint('✅ Password reset email sent to: $email');
      return AuthResult.success(null);
    } on FirebaseAuthException catch (e) {
      debugPrint('❌ Password reset error: ${e.code}');
      return AuthResult.failure(_getFirebaseErrorMessage(e));
    } catch (e) {
      debugPrint('❌ Password reset error: $e');
      return AuthResult.failure('Failed to send reset email. Please try again.');
    }
  }
  
  /// Get current user from Supabase
  static Future<AppUser?> getCurrentAppUser() async {
    final firebaseUser = currentFirebaseUser;
    if (firebaseUser == null) return null;
    
    try {
      return await _syncUserToSupabase(firebaseUser);
    } catch (e) {
      debugPrint('Error getting current user: $e');
      // Return basic user from Firebase data
      return AppUser(
        id: firebaseUser.uid,
        email: firebaseUser.email ?? '',
        name: firebaseUser.displayName,
        photoUrl: firebaseUser.photoURL,
        createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
        lastLogin: DateTime.now(),
      );
    }
  }
  
  /// Update user profile
  static Future<AuthResult> updateProfile({
    String? name,
    String? photoUrl,
  }) async {
    final firebaseUser = currentFirebaseUser;
    if (firebaseUser == null) {
      return AuthResult.failure('Not logged in');
    }
    
    try {
      // Update Firebase profile
      if (name != null && name.trim().isNotEmpty) {
        await firebaseUser.updateDisplayName(name.trim());
      }
      if (photoUrl != null) {
        await firebaseUser.updatePhotoURL(photoUrl);
      }
      
      // Reload to get updated user
      await firebaseUser.reload();
      
      // Update Supabase
      final updates = <String, dynamic>{
        'last_login': DateTime.now().toIso8601String(),
      };
      if (name != null) updates['name'] = name.trim();
      if (photoUrl != null) updates['photo_url'] = photoUrl;
      
      await _supabase
          .from('users')
          .update(updates)
          .eq('id', firebaseUser.uid);
      
      final updatedUser = await getCurrentAppUser();
      return AuthResult.success(updatedUser);
    } catch (e) {
      debugPrint('Update profile error: $e');
      return AuthResult.failure('Failed to update profile');
    }
  }
  
  /// Sync user to Supabase (create if not exists, update last_login)
  static Future<AppUser> _syncUserToSupabase(
    User firebaseUser, {
    String? name,
  }) async {
    final now = DateTime.now();
    final userName = name ?? 
        firebaseUser.displayName ?? 
        firebaseUser.email?.split('@').first ?? 
        'User';
    
    try {
      // Use upsert for atomic create-or-update
      final response = await _supabase.rpc('upsert_user', params: {
        'p_id': firebaseUser.uid,
        'p_email': firebaseUser.email ?? '',
        'p_name': userName,
        'p_photo_url': firebaseUser.photoURL,
      });
      
      if (response != null && (response as List).isNotEmpty) {
        return AppUser.fromJson(response[0]);
      }
      
      // Fallback: direct insert/update
      return await _syncUserDirect(firebaseUser, userName, now);
      
    } catch (e) {
      debugPrint('RPC upsert failed, trying direct: $e');
      // Fallback to direct insert/update
      return await _syncUserDirect(firebaseUser, userName, now);
    }
  }
  
  /// Direct sync to Supabase (fallback method)
  static Future<AppUser> _syncUserDirect(
    User firebaseUser,
    String userName,
    DateTime now,
  ) async {
    try {
      // Check if user exists
      final existing = await _supabase
          .from('users')
          .select()
          .eq('id', firebaseUser.uid)
          .maybeSingle();
      
      if (existing != null) {
        // Update last login
        await _supabase
            .from('users')
            .update({'last_login': now.toIso8601String()})
            .eq('id', firebaseUser.uid);
        
        return AppUser.fromJson(existing).copyWith(lastLogin: now);
      }
      
      // Create new user
      final userData = {
        'id': firebaseUser.uid,
        'email': firebaseUser.email ?? '',
        'name': userName,
        'photo_url': firebaseUser.photoURL,
        'created_at': now.toIso8601String(),
        'last_login': now.toIso8601String(),
      };
      
      await _supabase.from('users').insert(userData);
      debugPrint('✅ User synced to Supabase: ${firebaseUser.email}');
      
      return AppUser.fromJson(userData);
    } catch (e) {
      debugPrint('❌ Error syncing user to Supabase: $e');
      // Return a basic user even if Supabase sync fails
      return AppUser(
        id: firebaseUser.uid,
        email: firebaseUser.email ?? '',
        name: userName,
        photoUrl: firebaseUser.photoURL,
        createdAt: now,
        lastLogin: now,
      );
    }
  }
  
  /// Convert Firebase auth errors to user-friendly messages
  static String _getFirebaseErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':
        return 'This email is already registered. Try signing in instead.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'operation-not-allowed':
        return 'Email/password sign in is not enabled.';
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
        return 'Too many failed attempts. Please try again in a few minutes.';
      case 'network-request-failed':
        return 'Network error. Please check your internet connection.';
      case 'requires-recent-login':
        return 'Please sign in again to perform this action.';
      default:
        return e.message ?? 'An error occurred. Please try again.';
    }
  }
  
  /// Listen to auth state changes
  static Stream<User?> get authStateChanges {
    if (!isFirebaseConfigured) {
      return const Stream.empty();
    }
    try {
      return FirebaseAuth.instance.authStateChanges();
    } catch (e) {
      return const Stream.empty();
    }
  }
  
  /// Check if email is valid
  static bool isValidEmail(String email) {
    return RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(email);
  }
  
  /// Check if password is strong enough
  static String? validatePassword(String password) {
    if (password.isEmpty) {
      return 'Password is required';
    }
    if (password.length < 6) {
      return 'Password must be at least 6 characters';
    }
    return null;
  }
}
