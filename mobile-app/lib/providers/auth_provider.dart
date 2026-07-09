import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../config/app_firebase.dart';
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
  bool get isFirebaseConfigured => AppFirebase.isReady;
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
    if (!AppFirebase.isReady) return;
    _isInitialized = true;
    notifyListeners();
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
    // TEMP [AUTH][LISTENER] diagnostics — remove after latency is verified.
    debugPrint('[AUTH][LISTENER] fired user=${firebaseUser != null}');
    if (firebaseUser == null) {
      _currentUser = null;
      _verificationId = null;
      _resendToken = null;
      _pendingPhoneNumber = null;
      SupabaseAuthBridge.clearSupabaseSession();
      notifyListeners();
      return;
    }
    // Set the session user immediately so the UI can proceed. Everything below is
    // background work that MUST NOT block sign-in navigation.
    _currentUser = AuthService.appUserFromFirebase(firebaseUser);
    notifyListeners();

    if (AppFirebase.isReady) {
      final swf = Stopwatch()..start();
      NotificationService.onLogin(firebaseUser.uid)
          .then((_) => debugPrint('[AUTH][LISTENER] onLogin(FCM) done @${swf.elapsedMilliseconds}ms'));
    }
    final swb = Stopwatch()..start();
    firebaseUser.getIdToken().then((idToken) async {
      if (idToken != null && idToken.isNotEmpty) {
        debugPrint('[AUTH][BRIDGE] exchange start @${swb.elapsedMilliseconds}ms');
        final ok = await SupabaseAuthBridge.setSupabaseSessionFromFirebase(idToken);
        debugPrint('[AUTH][BRIDGE] exchange done ok=$ok @${swb.elapsedMilliseconds}ms');
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

  Future<bool> signInWithGoogle() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    // TEMP [AUTH][GOOGLE] timing diagnostics — remove after latency is verified.
    final sw = Stopwatch()..start();
    void mark(String step) => debugPrint('[AUTH][GOOGLE] $step @${sw.elapsedMilliseconds}ms');
    mark('start');
    try {
      final gsi = GoogleSignIn();
      // SPEED: no forced signOut(). The previous forced signOut() added a network
      // round-trip AND re-showed the account picker on every sign-in. signIn()
      // reuses the cached Google account silently when available (seconds, not a
      // minute). Account switching can be offered separately later if needed.
      final googleUser = await gsi.signIn();
      mark('gsi.signIn done (user=${googleUser != null})');
      if (googleUser == null) {
        _isLoading = false;
        notifyListeners();
        return false; // user cancelled
      }
      final googleAuth = await googleUser.authentication;
      mark('googleUser.authentication done');
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      // Fail fast instead of hanging ~60s if the network/Firebase call stalls.
      final userCredential = await FirebaseAuth.instance
          .signInWithCredential(credential)
          .timeout(const Duration(seconds: 30));
      mark('firebase.signInWithCredential done (user=${userCredential.user != null})');
      if (userCredential.user != null) {
        _currentUser = AuthService.appUserFromFirebase(userCredential.user!);
        _error = null;
        return true;
      }
      _error = 'Google sign-in failed. Please try again.';
      return false;
    } on TimeoutException {
      mark('TIMEOUT after 30s on signInWithCredential');
      _error = 'Sign-in timed out. Please check your connection and try again.';
      return false;
    } catch (e) {
      // Un-swallow the real cause (type/code only — never tokens) for diagnosis.
      mark('ERROR type=${e.runtimeType} detail=$e');
      _error = 'Google sign-in failed. Please try again.';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
      mark('finished total=${sw.elapsedMilliseconds}ms');
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
