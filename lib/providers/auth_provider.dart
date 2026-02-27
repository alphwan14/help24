import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../config/firebase_config.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/supabase_auth_bridge.dart';

/// Authentication state: session, phone OTP flow, errors.
/// Auth does NOT block the app; only protected actions require login.
class AuthProvider extends ChangeNotifier {
  AppUser? _currentUser;
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;
  StreamSubscription<User?>? _authSubscription;

  /// Phone OTP flow state
  String? _verificationId;
  int? _resendToken;
  String? _pendingPhoneNumber;

  AppUser? get currentUser => _currentUser;
  bool get isLoggedIn => _currentUser != null;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get error => _error;
  bool get isFirebaseConfigured => FirebaseConfig.isConfigured;
  String? get currentUserId => _currentUser?.id;
  String get currentUserName => _currentUser?.displayName ?? '';
  String? get currentUserEmail => _currentUser?.email;
  /// True if user just signed in (e.g. via phone) and has no name set — show profile setup.
  bool get needsProfileSetup =>
      _currentUser != null && !(_currentUser!.hasProfile);

  /// Verification ID and resend token after sendOtp (for verifyOtp / resend).
  String? get verificationId => _verificationId;
  int? get resendToken => _resendToken;
  String? get pendingPhoneNumber => _pendingPhoneNumber;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    notifyListeners();
    if (!FirebaseConfig.isConfigured) return;
    try {
      _authSubscription = AuthService.authStateChanges.listen(_onAuthStateChanged);
      final firebaseUser = AuthService.currentFirebaseUser;
      if (firebaseUser != null) {
        _currentUser = AuthService.appUserFromFirebase(firebaseUser);
        notifyListeners();
        try {
          final idToken = await firebaseUser.getIdToken();
          if (idToken != null && idToken.isNotEmpty) {
            await SupabaseAuthBridge.setSupabaseSessionFromFirebase(idToken);
          }
        } catch (_) {}
        AuthService.getCurrentAppUser().then((u) {
          if (u != null) {
            _currentUser = u;
            notifyListeners();
          }
        });
      }
    } catch (e) {
      debugPrint('Auth initialization error: $e');
    }
  }

  void _onAuthStateChanged(User? firebaseUser) {
    if (firebaseUser == null) {
      _currentUser = null;
      _verificationId = null;
      _resendToken = null;
      _pendingPhoneNumber = null;
      SupabaseAuthBridge.clearSupabaseSession();
      notifyListeners();
      return;
    }
    _currentUser = AuthService.appUserFromFirebase(firebaseUser);
    notifyListeners();
    if (FirebaseConfig.isConfigured) {
      NotificationService.onLogin(firebaseUser.uid);
    }
    firebaseUser.getIdToken().then((idToken) async {
      if (idToken != null && idToken.isNotEmpty) {
        await SupabaseAuthBridge.setSupabaseSessionFromFirebase(idToken);
      }
    }).catchError((_) {});
    AuthService.getCurrentAppUser().then((u) {
      if (u != null) {
        _currentUser = u;
        notifyListeners();
      }
    });
  }

  /// Start phone verification. On success, UI should navigate to OTP screen.
  Future<bool> sendOtp(String phoneNumber) async {
    if (!isFirebaseConfigured) {
      _error = 'Authentication is not configured.';
      notifyListeners();
      return false;
    }
    _isLoading = true;
    _error = null;
    _verificationId = null;
    _resendToken = null;
    _pendingPhoneNumber = null;
    notifyListeners();

    final completer = Completer<bool>();
    AuthService.verifyPhoneNumber(
      phoneNumber: phoneNumber,
      codeSent: (verificationId, resendToken) {
        if (!completer.isCompleted) {
          _verificationId = verificationId;
          _resendToken = resendToken;
          _pendingPhoneNumber = phoneNumber;
          _error = null;
          completer.complete(true);
        }
      },
      verificationFailed: (e) {
        if (!completer.isCompleted) {
          _error = AuthService.getPhoneErrorMessage(e);
          completer.complete(false);
        }
      },
      verificationCompleted: (credential) async {
        try {
          await FirebaseAuth.instance.signInWithCredential(credential);
          if (!completer.isCompleted) completer.complete(true);
        } catch (_) {
          if (!completer.isCompleted) {
            _error = 'Auto sign-in failed. Enter the code manually.';
            completer.complete(false);
          }
        }
      },
    );

    try {
      final ok = await completer.future.timeout(
        const Duration(seconds: 130),
        onTimeout: () {
          if (!completer.isCompleted) {
            _error = 'Verification timed out. Please try again.';
            completer.complete(false);
          }
          return false;
        },
      );
      return ok;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Verify OTP code. On success, currentUser is set; check needsProfileSetup for profile screen.
  Future<bool> verifyOtp(String code) async {
    final vid = _verificationId;
    if (vid == null || vid.isEmpty) {
      _error = 'Please request a new code.';
      notifyListeners();
      return false;
    }
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await AuthService.verifyOtp(verificationId: vid, smsCode: code);
      if (result.success && result.user != null) {
        _currentUser = result.user;
        _verificationId = null;
        _resendToken = null;
        _pendingPhoneNumber = null;
        _error = null;
        notifyListeners();
        return true;
      }
      _error = result.errorMessage ?? 'Verification failed.';
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Resend OTP (e.g. after 30s countdown). Uses stored resendToken if available.
  Future<bool> resendOtp() async {
    final phone = _pendingPhoneNumber;
    if (phone == null || phone.isEmpty) {
      _error = 'Enter your phone number again.';
      notifyListeners();
      return false;
    }
    return sendOtp(phone);
  }

  void clearPhoneState() {
    _verificationId = null;
    _resendToken = null;
    _pendingPhoneNumber = null;
    notifyListeners();
  }

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
        return true;
      }
      _error = result.errorMessage;
      return false;
    } catch (e) {
      _error = 'An unexpected error occurred';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signIn({
    required String email,
    required String password,
  }) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await AuthService.signIn(email: email, password: password);
      if (result.success) {
        _currentUser = result.user;
        _error = null;
        return true;
      }
      _error = result.errorMessage;
      return false;
    } catch (e) {
      _error = 'An unexpected error occurred';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    _isLoading = true;
    notifyListeners();
    try {
      await AuthService.signOut();
      _currentUser = null;
      _error = null;
      clearPhoneState();
    } catch (e) {
      _error = 'Failed to sign out';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> sendPasswordResetEmail(String email) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await AuthService.sendPasswordResetEmail(email);
      if (!result.success) _error = result.errorMessage;
      return result.success;
    } catch (e) {
      _error = 'An unexpected error occurred';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> updateProfile({String? name, String? photoUrl}) async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await AuthService.updateProfile(name: name, photoUrl: photoUrl);
      if (result.success && result.user != null) {
        _currentUser = result.user;
        return true;
      }
      _error = result.errorMessage;
      return false;
    } catch (e) {
      _error = 'Failed to update profile';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  /// Set error message (e.g. validation errors from UI).
  void setError(String? message) {
    _error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
