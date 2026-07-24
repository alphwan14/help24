import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../config/app_firebase.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/supabase_auth_bridge.dart';
import '../utils/auth_error_mapper.dart';

/// Authentication state: session, phone OTP flow, errors.
/// Auth does NOT block the app; only protected actions require login.
class AuthProvider extends ChangeNotifier {
  AppUser? _currentUser;
  bool _isLoading = false;
  bool _isInitialized = false;

  /// The current failure as structured data (headline + sentence + the one
  /// action that resolves it) rather than a bare string, so the UI can render
  /// a recovery BUTTON instead of a sentence the user cannot act on.
  AuthFailure? _failure;
  StreamSubscription<User?>? _authSubscription;
  /// The last uid whose one-time post-login side effects (FCM token, Supabase
  /// session exchange, profile sync) have run. Firebase fires authStateChanges
  /// several times per sign-in; this collapses the repeats so that work runs once.
  String? _lastHandledUid;

  /// Phone OTP flow state
  String? _verificationId;
  int? _resendToken;
  String? _pendingPhoneNumber;

  AppUser? get currentUser => _currentUser;
  bool get isLoggedIn => _currentUser != null;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;

  /// Structured failure for the auth UI.
  AuthFailure? get failure => _failure;

  /// Message-only view, for the call sites that just need a sentence.
  String? get error => _failure?.message;

  /// Whether the identity backend finished starting up. Named for what it
  /// means to the app, not for the vendor that provides it — this getter is
  /// read by UI code and the old name put a vendor in the call site.
  bool get isAuthAvailable => AppFirebase.isReady;

  /// True when the signed-in account has an unconfirmed email address.
  bool get needsEmailVerification =>
      _currentUser != null &&
      (_currentUser!.email.isNotEmpty) &&
      !AuthService.isEmailVerified;
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
      // Defensive: never stack two subscriptions (would double-fire every event).
      await _authSubscription?.cancel();
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
    final uid = firebaseUser?.uid;
    final isRepeat = uid == _lastHandledUid;
    _lastHandledUid = uid;

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

    // Firebase emits authStateChanges multiple times per sign-in (credential +
    // token refresh). Run the one-time side effects only once per actual user —
    // this eliminates the 3x FCM save / session exchange / profile sync.
    if (isRepeat) return;

    if (AppFirebase.isReady) {
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
  ///
  /// [phoneNumber] must already be E.164 (`+254712345678`) — the phone field
  /// guarantees this, so a malformed number can no longer reach the provider.
  Future<bool> sendOtp(String phoneNumber) async {
    if (!isAuthAvailable) {
      _failure = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'not-configured'),
        flow: AuthFlow.sendCode,
      );
      notifyListeners();
      return false;
    }
    _isLoading = true;
    _failure = null;
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
          _failure = null;
          completer.complete(true);
        }
      },
      verificationFailed: (e) {
        if (!completer.isCompleted) {
          _failure = AuthService.getPhoneFailure(e);
          completer.complete(false);
        }
      },
      verificationCompleted: (credential) async {
        // Android instant verification: the SMS was read automatically and
        // there is no code for the user to type. Treated as a full success so
        // the OTP screen can skip straight through.
        try {
          await FirebaseAuth.instance.signInWithCredential(credential);
          _autoVerified = true;
          if (!completer.isCompleted) completer.complete(true);
          notifyListeners();
        } catch (e) {
          // Auto sign-in failed, but the SMS is still on its way — this is not
          // a dead end, so say nothing and let the user type the code.
          debugPrint('[AUTH] instant verification unavailable: ${e.runtimeType}');
          if (!completer.isCompleted) completer.complete(true);
        }
      },
    );

    try {
      final ok = await completer.future.timeout(
        const Duration(seconds: 130),
        onTimeout: () {
          if (!completer.isCompleted) {
            _failure = const AuthFailure(
              title: "We couldn't send your code",
              message: 'That took longer than expected. Please try again.',
            );
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

  /// True when the SMS was read and consumed by the device without the user
  /// typing anything. The OTP screen uses this to advance on its own.
  bool _autoVerified = false;
  bool get autoVerified => _autoVerified;

  /// Verify OTP code. On success, currentUser is set; check needsProfileSetup for profile screen.
  Future<bool> verifyOtp(String code) async {
    final vid = _verificationId;
    if (vid == null || vid.isEmpty) {
      _failure = const AuthFailure(
        title: 'Let’s start over',
        message: 'This verification is no longer valid. Enter your number again.',
        recovery: AuthRecovery.restartPhone,
      );
      notifyListeners();
      return false;
    }
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final result = await AuthService.verifyOtp(verificationId: vid, smsCode: code);
      if (result.success && result.user != null) {
        _currentUser = result.user;
        _verificationId = null;
        _resendToken = null;
        _pendingPhoneNumber = null;
        _failure = null;
        notifyListeners();
        return true;
      }
      _failure = result.failure;
      notifyListeners();
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Resend OTP (e.g. after the countdown). Reuses the pending number.
  Future<bool> resendOtp() async {
    final phone = _pendingPhoneNumber;
    if (phone == null || phone.isEmpty) {
      _failure = const AuthFailure(
        title: 'Let’s start over',
        message: 'Enter your phone number again to get a new code.',
        recovery: AuthRecovery.restartPhone,
      );
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

  /// Is there already an account for this email? Drives the identity-first
  /// flow: the user types their email once and is routed to the correct next
  /// step instead of choosing "Sign In" vs "Sign Up" up front.
  Future<AccountStatus> lookupAccount(String email) =>
      AuthService.lookupAccount(email);

  Future<bool> signUp({
    required String email,
    required String password,
    String? name,
  }) async {
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final result = await AuthService.signUp(
        email: email,
        password: password,
        name: name,
      );
      if (result.success) {
        _currentUser = result.user;
        _failure = null;
        return true;
      }
      _failure = result.failure;
      return false;
    } catch (e) {
      _failure = AuthErrorMapper.toFailure(e, flow: AuthFlow.signUp);
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
    _failure = null;
    notifyListeners();
    try {
      final result = await AuthService.signIn(email: email, password: password);
      if (result.success) {
        _currentUser = result.user;
        _failure = null;
        return true;
      }
      _failure = result.failure;
      return false;
    } catch (e) {
      _failure = AuthErrorMapper.toFailure(e, flow: AuthFlow.signIn);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> signInWithGoogle() async {
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final gsi = GoogleSignIn();
      // Always show the account chooser — the user may have several Google accounts
      // and must pick explicitly (never silent auto-login). signOut() clears only the
      // LOCAL cached selection so the picker re-appears; it's a fast local op.
      await gsi.signOut();
      final googleUser = await gsi.signIn();
      if (googleUser == null) {
        // User dismissed the chooser. A cancellation is not a failure and must
        // never produce an error banner.
        _isLoading = false;
        notifyListeners();
        return false;
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      // Fail fast instead of hanging if the network call stalls.
      final userCredential = await FirebaseAuth.instance
          .signInWithCredential(credential)
          .timeout(const Duration(seconds: 30));
      if (userCredential.user != null) {
        _currentUser = AuthService.appUserFromFirebase(userCredential.user!);
        _failure = null;
        return true;
      }
      _failure = AuthErrorMapper.toFailure(null, flow: AuthFlow.signIn);
      return false;
    } catch (e) {
      // Mapped, never echoed: the platform's own text here is full of OAuth
      // and browser-handoff vocabulary the user cannot act on.
      _failure = AuthErrorMapper.toFailure(e, flow: AuthFlow.signIn);
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
      // Push hygiene: a signed-out device must not keep receiving this
      // account's notifications. Best-effort (never blocks sign-out).
      final uid = _currentUser?.id;
      if (uid != null && uid.isNotEmpty) {
        await NotificationService.removeTokenOnLogout(uid);
      }
      await AuthService.signOut();
      _currentUser = null;
      _failure = null;
      clearPhoneState();
    } catch (e) {
      debugPrint('[AUTH] sign-out cleanup failed: ${e.runtimeType}');
      // The local session is gone either way — never trap the user in a
      // signed-in state because a cleanup call failed.
      _currentUser = null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> sendPasswordResetEmail(String email) async {
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final result = await AuthService.sendPasswordResetEmail(email);
      if (!result.success) _failure = result.failure;
      return result.success;
    } catch (e) {
      _failure = AuthErrorMapper.toFailure(e, flow: AuthFlow.passwordReset);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Re-send the address-confirmation email.
  Future<bool> sendVerificationEmail() async {
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final result = await AuthService.sendVerificationEmail();
      if (!result.success) _failure = result.failure;
      return result.success;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Poll the server for a verification that happened in the user's mail app.
  Future<bool> refreshEmailVerified() async {
    final verified = await AuthService.refreshEmailVerified();
    notifyListeners();
    return verified;
  }

  Future<bool> updateProfile({String? name, String? photoUrl}) async {
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final result = await AuthService.updateProfile(name: name, photoUrl: photoUrl);
      if (result.success && result.user != null) {
        _currentUser = result.user;
        return true;
      }
      _failure = result.failure;
      return false;
    } catch (e) {
      _failure = AuthErrorMapper.toFailure(e, flow: AuthFlow.generic);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearError() {
    _failure = null;
    notifyListeners();
  }

  /// Surface a validation failure raised by the UI itself (empty field, bad
  /// email shape). Takes structured copy so these read like every other
  /// failure in the flow.
  void setFailure(AuthFailure? failure) {
    _failure = failure;
    notifyListeners();
  }

  /// Convenience for simple one-line validation messages.
  void setError(String? message, {String title = 'Check that again'}) {
    _failure = message == null
        ? null
        : AuthFailure(title: title, message: message);
    notifyListeners();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }
}
