import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../config/firebase_config.dart';

/// Authentication state provider
/// 
/// Exposes:
/// - isLoggedIn: whether user is authenticated
/// - currentUser: the current AppUser (or null)
/// - isLoading: whether an auth operation is in progress
/// - error: any error message from the last operation
class AuthProvider extends ChangeNotifier {
  AppUser? _currentUser;
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;
  StreamSubscription<User?>? _authSubscription;
  
  // Getters
  AppUser? get currentUser => _currentUser;
  bool get isLoggedIn => _currentUser != null;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get error => _error;
  bool get isFirebaseConfigured => FirebaseConfig.isConfigured;
  
  /// Get current user ID (Firebase UID)
  String? get currentUserId => _currentUser?.id;
  
  /// Get current user name
  String get currentUserName => _currentUser?.name ?? 'Guest';
  
  /// Get current user email
  String? get currentUserEmail => _currentUser?.email;
  
  /// Initialize the auth provider
  /// Call this after Firebase is initialized
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    _isLoading = true;
    notifyListeners();
    
    try {
      if (FirebaseConfig.isConfigured) {
        // Listen to auth state changes
        _authSubscription = AuthService.authStateChanges.listen(_onAuthStateChanged);
        
        // Check if already logged in
        if (AuthService.isLoggedIn) {
          _currentUser = await AuthService.getCurrentAppUser();
        }
      }
    } catch (e) {
      debugPrint('Auth initialization error: $e');
    } finally {
      _isInitialized = true;
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// Handle auth state changes from Firebase
  Future<void> _onAuthStateChanged(User? firebaseUser) async {
    if (firebaseUser == null) {
      _currentUser = null;
    } else {
      _currentUser = await AuthService.getCurrentAppUser();
    }
    notifyListeners();
  }
  
  /// Sign up with email and password
  Future<bool> signUp({
    required String email,
    required String password,
    String? name,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    
    try {
      final result = await AuthService.signUp(
        email: email,
        password: password,
        name: name,
      );
      
      if (result.success) {
        _currentUser = result.user;
        _error = null;
        notifyListeners();
        return true;
      } else {
        _error = result.errorMessage;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'An unexpected error occurred';
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// Sign in with email and password
  Future<bool> signIn({
    required String email,
    required String password,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    
    try {
      final result = await AuthService.signIn(
        email: email,
        password: password,
      );
      
      if (result.success) {
        _currentUser = result.user;
        _error = null;
        notifyListeners();
        return true;
      } else {
        _error = result.errorMessage;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _error = 'An unexpected error occurred';
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// Sign out
  Future<void> signOut() async {
    _isLoading = true;
    notifyListeners();
    
    try {
      await AuthService.signOut();
      _currentUser = null;
      _error = null;
    } catch (e) {
      _error = 'Failed to sign out';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// Send password reset email
  Future<bool> sendPasswordResetEmail(String email) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    
    try {
      final result = await AuthService.sendPasswordResetEmail(email);
      
      if (!result.success) {
        _error = result.errorMessage;
      }
      
      return result.success;
    } catch (e) {
      _error = 'An unexpected error occurred';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// Update user profile
  Future<bool> updateProfile({String? name, String? photoUrl}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    
    try {
      final result = await AuthService.updateProfile(
        name: name,
        photoUrl: photoUrl,
      );
      
      if (result.success && result.user != null) {
        _currentUser = result.user;
        return true;
      } else {
        _error = result.errorMessage;
        return false;
      }
    } catch (e) {
      _error = 'Failed to update profile';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  /// Clear error
  void clearError() {
    _error = null;
    notifyListeners();
  }
  
  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
