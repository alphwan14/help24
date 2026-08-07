import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../config/app_firebase.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/notification_service.dart';
import '../services/session_scope.dart';
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
    final previousUid = _lastHandledUid;
    final isRepeat = uid == _lastHandledUid;
    _lastHandledUid = uid;

    if (firebaseUser == null) {
      _currentUser = null;
      _verificationId = null;
      _resendToken = null;
      _pendingPhoneNumber = null;
      SupabaseAuthBridge.clearSupabaseSession();
      // Both credentials are dropped together. The Supabase JWT and the cached
      // Firebase ID token are different tokens for different servers (see
      // api_client.dart), so clearing one and not the other would leave the
      // backend still receiving the previous user's proof of identity —
      // precisely the confusion this migration exists to remove.
      api.clearSession();
      // The session can also end without anyone pressing "Sign out" — a
      // revoked token, a deleted account, a sign-out on another device. Those
      // paths must tear down exactly as much state as the button does, so the
      // teardown hangs off the auth state itself rather than off the UI action.
      // Idempotent: a normal sign-out reaches this after signOut() already ran.
      unawaited(_endSession(previousUid));
      notifyListeners();
      return;
    }

    // A DIFFERENT user just signed in on this device. Anything still held from
    // the previous session is destroyed before the new session populates, so a
    // switch can never blend two accounts — even if the previous sign-out was
    // interrupted or never completed cleanly.
    if (previousUid != null && previousUid.isNotEmpty && previousUid != uid) {
      debugPrint('[SESSION] account switch detected — clearing prior session');
      // BOTH CREDENTIAL CACHES FIRST, SYNCHRONOUSLY.
      //
      // A switch does not always pass through null: signing in with a second
      // Google account calls signInWithCredential on a live session, so Firebase
      // emits B directly after A. The sign-out branch above drops both cached
      // credentials; this branch used to drop neither, and they are not
      // short-lived — the Supabase JWT is reused for 50 minutes and the Firebase
      // ID token is cached until shortly before its expiry.
      //
      // Until the re-exchange below completed, every RLS-scoped read still
      // carried A's `user_id` claim while the app believed it was B: B's
      // conversations, notifications and saved items would have been answered
      // with A's rows. Clearing here makes the worst case "a read has no
      // credential yet and returns nothing", which is recoverable, instead of
      // "a read has the WRONG credential and returns someone else's data",
      // which is not.
      SupabaseAuthBridge.clearSupabaseSession();
      api.clearSession();
      unawaited(_endSession(previousUid));
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

  /// Run the Google account chooser and return a Firebase credential.
  ///
  /// Null means the user dismissed the chooser — a cancellation, not a failure,
  /// and it must never produce an error banner. Shared by [signInWithGoogle]
  /// and [linkGoogle] so the two can never drift on which account the chooser
  /// offers or how a dismissal is read.
  Future<AuthCredential?> _pickGoogleCredential() async {
    final gsi = GoogleSignIn();
    // Always show the account chooser — the user may have several Google accounts
    // and must pick explicitly (never silent auto-login). signOut() clears only the
    // LOCAL cached selection so the picker re-appears; it's a fast local op.
    await gsi.signOut();
    final googleUser = await gsi.signIn();
    if (googleUser == null) return null;
    final googleAuth = await googleUser.authentication;
    return GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
  }

  Future<bool> signInWithGoogle() async {
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final credential = await _pickGoogleCredential();
      if (credential == null) {
        _isLoading = false;
        notifyListeners();
        return false;
      }
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

  // ─── Linking a second sign-in method to THIS account ────────────────────
  //
  // Every method below attaches a credential to the uid already signed in. None
  // of them can create an account: `linkWithCredential` is defined on the
  // current user, so there is no argument that could name a different one. That
  // is what makes "one human, one uid" a property of the code rather than a
  // hope about how people will use it.

  /// The credentials on this account (`google.com`, `password`, `phone`).
  List<String> get signInMethods => AuthService.signInMethods;
  bool get hasPassword => AuthService.hasPassword;
  bool get hasGoogle => AuthService.hasGoogle;
  bool get hasPhone => AuthService.hasPhone;

  /// Add a password to the account the user is already signed in to.
  Future<bool> linkEmailPassword({
    required String email,
    required String password,
  }) async {
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final result =
          await AuthService.linkEmailPassword(email: email, password: password);
      if (result.success) {
        if (result.user != null) _currentUser = result.user;
        _failure = null;
        return true;
      }
      _failure = result.failure;
      return false;
    } catch (e) {
      _failure = AuthErrorMapper.toFailure(e, flow: AuthFlow.linkMethod);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Add Google to the account the user is already signed in to.
  ///
  /// Returns false with no failure set when the chooser was dismissed.
  Future<bool> linkGoogle() async {
    final user = AuthService.currentFirebaseUser;
    if (user == null) {
      _failure = const AuthFailure(
        title: 'Sign in to continue',
        message: 'Sign in first, then you can add another way in.',
      );
      notifyListeners();
      return false;
    }
    _isLoading = true;
    _failure = null;
    notifyListeners();
    try {
      final credential = await _pickGoogleCredential();
      if (credential == null) return false;
      final result =
          await user.linkWithCredential(credential).timeout(const Duration(seconds: 30));
      final linked = result.user ?? user;
      await linked.reload();
      debugPrint('[AUTH][LINK] google attached to ${linked.uid}');
      _currentUser = AuthService.appUserFromFirebase(
        AuthService.currentFirebaseUser ?? linked,
      );
      _failure = null;
      return true;
    } catch (e) {
      _failure = AuthErrorMapper.toFailure(e, flow: AuthFlow.linkMethod);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Add a verified phone number to the account already signed in.
  ///
  /// Consumes the same OTP state [sendOtp] populates, so the phone step needs
  /// no second implementation — the only difference from [verifyOtp] is that
  /// the credential is linked rather than signed in with.
  Future<bool> linkPhone(String code) async {
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
      final result =
          await AuthService.linkPhone(verificationId: vid, smsCode: code);
      if (result.success) {
        if (result.user != null) _currentUser = result.user;
        clearPhoneState();
        _failure = null;
        return true;
      }
      _failure = result.failure;
      return false;
    } catch (e) {
      _failure = AuthErrorMapper.toFailure(e, flow: AuthFlow.linkMethod);
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    _isLoading = true;
    notifyListeners();
    final uid = _currentUser?.id;
    try {
      // Push hygiene: a signed-out device must not keep receiving this
      // account's notifications. Best-effort (never blocks sign-out).
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
      // Ending the session is NOT part of the try: a failed token removal or a
      // provider error must never leave the previous account's caches on the
      // device. This is the one step that has to happen unconditionally.
      await _endSession(uid);
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Destroy every user-scoped cache, stream and provider cache for [uid].
  ///
  /// Sign-out used to clear only the identity (`_currentUser` + the Supabase
  /// JWT) and leave everything derived from it in place, which is how one
  /// account's conversations survived into the next session. Session teardown
  /// is now a single owned operation — see [SessionScope].
  Future<void> _endSession(String? uid) async {
    try {
      await SessionScope.instance.endSession(uid);
    } catch (e) {
      debugPrint('[AUTH] session teardown error: ${e.runtimeType}');
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

  /// Load the authoritative profile from our own store and adopt its name.
  ///
  /// [needsProfileSetup] is derived from the identity provider's `displayName`,
  /// which phone accounts frequently do not carry — the name lives in the
  /// Help24 profile, not in the credential. Without this, a RETURNING phone
  /// user who signs in successfully is sent to "choose your name" and the auth
  /// screen never dismisses: authentication worked, but the user is stuck
  /// looking at it. Called before that routing decision is made.
  ///
  /// Returns true once the account is known to have a usable name.
  Future<bool> resolveProfile() async {
    if (_currentUser == null) return false;
    try {
      final resolved = await AuthService.getCurrentAppUser()
          .timeout(const Duration(seconds: 6));
      if (resolved != null) {
        _currentUser = resolved;
        notifyListeners();
      }
    } catch (e) {
      // Unresolvable (offline, slow): fall through to whatever we already know.
      // Asking a returning user for their name once is recoverable; blocking
      // sign-in on a profile read is not.
      debugPrint('[AUTH] profile resolve unavailable: ${e.runtimeType}');
    }
    return _currentUser?.hasProfile ?? false;
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
