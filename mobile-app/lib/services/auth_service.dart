import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../config/app_firebase.dart';
import '../config/app_urls.dart';
import '../utils/auth_error_mapper.dart';
import '../utils/error_mapper.dart';
import '../utils/kenyan_phone.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'user_profile_service.dart';

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
    final avatar = json['avatar_url'] as String? ?? json['profile_image'] as String? ?? json['photo_url'] as String?;
    return AppUser(
      id: json['id'] as String,
      email: json['email'] as String? ?? '',
      name: json['name'] as String?,
      phoneNumber: json['phone_number'] as String? ?? json['phone'] as String?,
      photoUrl: avatar,
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

  String get displayName => (name != null && name!.trim().isNotEmpty) ? name! : (email.isNotEmpty ? email.split('@').first : (phoneNumber != null && phoneNumber!.isNotEmpty ? phoneNumber! : '?'));
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
  final AppUser? user;

  /// Structured, white-labelled failure — title, sentence, and the one action
  /// that resolves it. Null on success.
  ///
  /// Callers must render THIS rather than any provider text: it is the only
  /// object in the auth path guaranteed free of vendor vocabulary.
  final AuthFailure? failure;

  AuthResult.success(this.user)
      : success = true,
        failure = null;

  AuthResult.failed(this.failure)
      : success = false,
        user = null;

  /// Build a failure straight from a caught error, mapping it in one step.
  factory AuthResult.from(Object? error, AuthFlow flow) =>
      AuthResult.failed(AuthErrorMapper.toFailure(error, flow: flow));

  String? get errorMessage => failure?.message;
}

/// What we know about an email address before asking for a password.
///
/// Used to route the user to the right next step instead of making them guess
/// between "Sign In" and "Sign Up" before they have typed anything.
enum AccountStatus {
  /// An account exists — ask for the password.
  exists,

  /// No account — offer to create one.
  none,

  /// Could not be determined. Modern identity platforms enable email-
  /// enumeration protection by default, which deliberately makes existence
  /// unknowable from the client (it is an account-harvesting defence). When
  /// this comes back, the UI proceeds optimistically to the password step and
  /// recovers from whatever the sign-in attempt actually reports.
  unknown,
}

/// Phone verification state (held by AuthProvider after sendOtp).
class PhoneVerificationState {
  final String verificationId;
  final int? resendToken;

  PhoneVerificationState({required this.verificationId, this.resendToken});
}

/// Authentication service: Firebase (phone OTP + email) + Supabase user sync.
class AuthService {
  static final _supabase = Supabase.instance.client;

  /// Ceiling for Firebase email auth calls. These go through the Firebase SDK,
  /// not [HttpClientWithToken], so they need their own bound — otherwise a
  /// stall on a dead connection leaves the sign-in button spinning forever.
  static const Duration _authTimeout = Duration(seconds: 30);

  static bool get isFirebaseConfigured => AppFirebase.isReady;

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
        message: 'Identity provider unavailable (developer log only).',
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

  /// Last line of defence before a number reaches the provider.
  ///
  /// The UI now hands over a validated E.164 string from [KenyanPhone], so
  /// this should be a no-op — but a number arriving from an older call path
  /// (a stored profile value, a resend) still gets normalised rather than
  /// being sent as `+2540712345678`.
  static String _normalizePhone(String phone) {
    final e164 = KenyanPhone.toE164(phone);
    if (e164 != null) return e164;
    // Not a Kenyan mobile: pass through in E.164 shape and let the provider
    // reject it, which the mapper turns into "Check your number".
    final trimmed = phone.replaceAll(RegExp(r'\s'), '');
    return trimmed.startsWith('+') ? trimmed : '+$trimmed';
  }

  /// Verify OTP and sign in. Returns success with user or failure with message.
  static Future<AuthResult> verifyOtp({
    required String verificationId,
    required String smsCode,
  }) async {
    if (!isFirebaseConfigured) {
      return AuthResult.from(
        FirebaseAuthException(code: 'not-configured'),
        AuthFlow.verifyCode,
      );
    }
    final auth = _firebaseAuth!;
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode.trim(),
      );
      final result = await auth.signInWithCredential(credential);
      final user = result.user;
      if (user == null) {
        return AuthResult.from(null, AuthFlow.verifyCode);
      }
      final phone = user.phoneNumber ?? _normalizePhone(user.uid);
      await UserProfileService.createUserOnSignup(
        uid: user.uid,
        email: user.email ?? '',
        name: user.displayName,
        phone: phone,
      );
      await UserProfileService.setOnline(user.uid, true);
      final appUser = _appUserFromFirebase(user, nameOverride: user.displayName);
      debugPrint('✅ Phone sign in: ${appUser.id}');
      _syncUserToSupabase(user, name: user.displayName, phoneNumber: phone).then((_) => debugPrint('✅ User synced to Supabase'));
      return AuthResult.success(appUser);
    } catch (e) {
      return AuthResult.from(e, AuthFlow.verifyCode);
    }
  }

  /// Phone-flow failures, mapped to Help24 copy.
  ///
  /// Previously this ended in `return e.message ?? …`, which is precisely how
  /// the provider's "Play Integrity checks and reCAPTCHA checks were
  /// unsuccessful" sentence reached real users. The mapper now owns every
  /// branch and the raw text is logged, never shown.
  static AuthFailure getPhoneFailure(FirebaseAuthException e) =>
      AuthErrorMapper.toFailure(e, flow: AuthFlow.sendCode);

  // ---------- Email ----------

  /// Settings applied to every outbound auth email (reset, verification).
  ///
  /// `url` is where the user lands after the link is consumed, and it is what
  /// makes the hand-off read as Help24 rather than as an anonymous vendor
  /// page. The link's own host is set by the custom auth domain configured in
  /// the identity console — see `_docs/AUTH_WHITE_LABEL_AUDIT.md`; it cannot
  /// be overridden from the client.
  /// Must match `applicationId` in android/app/build.gradle — a mismatch makes
  /// the platform reject the settings and silently fall back to an unbranded
  /// link, which is the exact failure this whole change set exists to prevent.
  static const String _androidPackageName = 'com.help24.help24';

  static ActionCodeSettings get _actionCodeSettings => ActionCodeSettings(
        url: AppUrls.authContinueUrl,
        handleCodeInApp: false,
        androidPackageName: _androidPackageName,
        androidInstallApp: false,
        androidMinimumVersion: '21',
      );

  /// Does an account already exist for [email]?
  ///
  /// WHY THIS IS BEST-EFFORT AND WHY THAT IS FINE
  /// -------------------------------------------
  /// Identity platforms now ship email-enumeration protection ON by default:
  /// the lookup returns an empty list for every address, precisely so that an
  /// attacker cannot use this endpoint to harvest which emails are registered.
  /// That is a defence worth keeping — so this returns [AccountStatus.unknown]
  /// rather than pretending, and the UI is built to recover gracefully from
  /// whatever the subsequent sign-in attempt reports.
  ///
  /// When the protection is disabled the answer is authoritative and the user
  /// gets the ideal single-step routing.
  ///
  /// The underlying call is deprecated for exactly this reason. It is kept
  /// because it is a strict UX upgrade where it still works, it is bounded by
  /// a timeout, and it fails closed to [AccountStatus.unknown] — so the flow
  /// is already correct for the day the method disappears. Deleting this
  /// method would change nothing a user can see.
  static Future<AccountStatus> lookupAccount(String email) async {
    final auth = _firebaseAuth;
    if (auth == null) return AccountStatus.unknown;
    try {
      final methods = await auth
          // ignore: deprecated_member_use
          .fetchSignInMethodsForEmail(email.trim())
          .timeout(const Duration(seconds: 8));
      if (methods.isNotEmpty) return AccountStatus.exists;
      // Empty is ambiguous: either genuinely no account, or enumeration
      // protection is on. Never assert "no account" from this alone.
      return AccountStatus.unknown;
    } catch (e) {
      debugPrint('[AUTH] account lookup inconclusive: ${e.runtimeType}');
      return AccountStatus.unknown;
    }
  }

  static Future<AuthResult> signUp({
    required String email,
    required String password,
    String? name,
  }) async {
    final auth = _firebaseAuth;
    if (!isFirebaseConfigured || auth == null) {
      return AuthResult.from(
        FirebaseAuthException(code: 'not-configured'),
        AuthFlow.signUp,
      );
    }
    try {
      final credential = await auth
          .createUserWithEmailAndPassword(
            email: email.trim(),
            password: password,
          )
          .timeout(_authTimeout);
      final firebaseUser = credential.user;
      if (firebaseUser == null) return AuthResult.from(null, AuthFlow.signUp);
      if (name != null && name.trim().isNotEmpty) {
        await firebaseUser.updateDisplayName(name.trim());
        await firebaseUser.reload();
      }
      final current = auth.currentUser ?? firebaseUser;

      // Prove the address is real. Without this, anyone can register with
      // someone else's email, and every password-reset path for that account
      // then points at a mailbox its owner never confirmed. Best-effort: a
      // failure to send must not block a successful account creation.
      unawaited(sendVerificationEmail());

      final appUser = _appUserFromFirebase(current, nameOverride: name?.trim());
      debugPrint('✅ Account created: ${appUser.id}');
      await UserProfileService.createUserOnSignup(
        uid: current.uid,
        email: current.email ?? '',
        name: name?.trim(),
      );
      unawaited(_syncUserToSupabase(current, name: name?.trim()));
      return AuthResult.success(appUser);
    } catch (e) {
      return AuthResult.from(e, AuthFlow.signUp);
    }
  }

  static Future<AuthResult> signIn({
    required String email,
    required String password,
  }) async {
    final auth = _firebaseAuth;
    if (!isFirebaseConfigured || auth == null) {
      return AuthResult.from(
        FirebaseAuthException(code: 'not-configured'),
        AuthFlow.signIn,
      );
    }
    try {
      final credential = await auth
          .signInWithEmailAndPassword(
            email: email.trim(),
            password: password,
          )
          .timeout(_authTimeout);
      final firebaseUser = credential.user;
      if (firebaseUser == null) return AuthResult.from(null, AuthFlow.signIn);
      await UserProfileService.setOnline(firebaseUser.uid, true);
      final appUser = _appUserFromFirebase(firebaseUser);
      debugPrint('✅ Signed in: ${appUser.id}');
      unawaited(_syncUserToSupabase(firebaseUser));
      return AuthResult.success(appUser);
    } catch (e) {
      return AuthResult.from(e, AuthFlow.signIn);
    }
  }

  // ---------- Email verification ----------

  /// True when the signed-in user's email has been confirmed. Phone-only
  /// accounts have no email to verify and are reported as verified so they are
  /// never nagged.
  static bool get isEmailVerified {
    final user = currentFirebaseUser;
    if (user == null) return false;
    if ((user.email ?? '').isEmpty) return true;
    return user.emailVerified;
  }

  /// Send (or re-send) the address-confirmation email.
  static Future<AuthResult> sendVerificationEmail() async {
    final user = currentFirebaseUser;
    if (user == null || (user.email ?? '').isEmpty) {
      return AuthResult.from(null, AuthFlow.generic);
    }
    try {
      await user
          .sendEmailVerification(_actionCodeSettings)
          .timeout(_authTimeout);
      debugPrint('✅ Verification email dispatched');
      return AuthResult.success(null);
    } catch (e) {
      return AuthResult.from(e, AuthFlow.generic);
    }
  }

  /// Re-read the account from the server to pick up a verification that
  /// happened in the user's mail app. The local user object caches
  /// `emailVerified`, so without this refresh the app would keep showing the
  /// "confirm your email" prompt after the user had already done it.
  static Future<bool> refreshEmailVerified() async {
    final user = currentFirebaseUser;
    if (user == null) return false;
    try {
      await user.reload().timeout(const Duration(seconds: 10));
      return currentFirebaseUser?.emailVerified ?? false;
    } catch (e) {
      debugPrint('[AUTH] verification refresh failed: ${e.runtimeType}');
      return false;
    }
  }

  static Future<void> signOut() async {
    try {
      final uid = currentUserId;
      if (uid != null) await UserProfileService.setOnline(uid, false);
      await _firebaseAuth?.signOut();
      debugPrint('✅ User signed out');
    } catch (e) {
      debugPrint('❌ Sign out error: $e');
    }
  }

  /// Send a password-reset link.
  ///
  /// Deliberately reports success even when the address has no account: a
  /// reset form that says "no such user" is an account-enumeration oracle, and
  /// the UI copy ("if this email is registered, we've sent a link") is written
  /// to be true either way. Only genuine transport failures surface an error.
  static Future<AuthResult> sendPasswordResetEmail(String email) async {
    final auth = _firebaseAuth;
    if (!isFirebaseConfigured || auth == null) {
      return AuthResult.from(
        FirebaseAuthException(code: 'not-configured'),
        AuthFlow.passwordReset,
      );
    }
    try {
      await auth
          .sendPasswordResetEmail(
            email: email.trim(),
            actionCodeSettings: _actionCodeSettings,
          )
          .timeout(_authTimeout);
      debugPrint('✅ Password reset dispatched');
      return AuthResult.success(null);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') {
        // Same outcome as success — see above.
        debugPrint('[AUTH] reset requested for unregistered address (masked)');
        return AuthResult.success(null);
      }
      return AuthResult.from(e, AuthFlow.passwordReset);
    } catch (e) {
      return AuthResult.from(e, AuthFlow.passwordReset);
    }
  }

  /// Ensures the current Firebase user exists in Supabase `users` table.
  /// Call this before creating a post/job so `posts.author_user_id` FK is satisfied.
  static Future<void> ensureCurrentUserInSupabase() async {
    final firebaseUser = currentFirebaseUser;
    if (firebaseUser == null) return;
    await _syncUserToSupabase(
      firebaseUser,
      phoneNumber: firebaseUser.phoneNumber,
    );
  }

  /// Build AppUser from Firebase only (no network). Use for instant UI update so login never freezes.
  static AppUser appUserFromFirebase(User firebaseUser, {String? nameOverride}) {
    return _appUserFromFirebase(firebaseUser, nameOverride: nameOverride);
  }

  static AppUser _appUserFromFirebase(User firebaseUser, {String? nameOverride}) {
    final email = firebaseUser.email ?? '';
    final name = nameOverride ?? firebaseUser.displayName ?? (email.isNotEmpty ? email.split('@').first : null);
    return AppUser(
      id: firebaseUser.uid,
      email: email,
      name: name?.trim().isEmpty == true ? null : name,
      phoneNumber: firebaseUser.phoneNumber,
      photoUrl: firebaseUser.photoURL,
      createdAt: firebaseUser.metadata.creationTime ?? DateTime.now(),
      lastLogin: DateTime.now(),
    );
  }

  static Future<AppUser?> getCurrentAppUser() async {
    final firebaseUser = currentFirebaseUser;
    if (firebaseUser == null) return null;
    try {
      return await _syncUserToSupabase(
        firebaseUser,
        phoneNumber: firebaseUser.phoneNumber,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () => _appUserFromFirebase(firebaseUser),
      );
    } catch (e) {
      debugPrint('Error getting current user: $e');
      return _appUserFromFirebase(firebaseUser);
    }
  }

  static Future<AuthResult> updateProfile({
    String? name,
    String? photoUrl,
  }) async {
    final firebaseUser = currentFirebaseUser;
    if (firebaseUser == null) {
      return AuthResult.failed(const AuthFailure(
        title: 'Sign in to continue',
        message: 'Please sign in to update your profile.',
      ));
    }
    try {
      if (name != null && name.trim().isNotEmpty) await firebaseUser.updateDisplayName(name.trim());
      if (photoUrl != null) await firebaseUser.updatePhotoURL(photoUrl);
      await firebaseUser.reload();
      final updates = <String, dynamic>{'last_login': DateTime.now().toUtc().toIso8601String()};
      if (name != null) updates['name'] = name.trim();
      if (photoUrl != null) {
        updates['profile_image'] = photoUrl;
        updates['avatar_url'] = photoUrl;
      }
      await _supabase.from('users').update(updates).eq('id', firebaseUser.uid);
      final updatedUser = await getCurrentAppUser();
      return AuthResult.success(updatedUser);
    } catch (e) {
      // The name-change cooldown (migration 087) surfaces here as a database
      // rejection; the mapper turns its marker into the "you can change it
      // again in N days" rule rather than an error.
      debugPrint('[AUTH] profile update failed: ${e.runtimeType}');
      return AuthResult.failed(AuthFailure(
        title: "We couldn't save that",
        message: ErrorMapper.toMessage(e, context: ErrorContext.save),
      ));
    }
  }

  /// Sync Firebase user to Supabase users table (no RPC).
  /// Uses client-side upsert: id = Firebase UID. Name = email prefix if no name; never use "Guest".
  static Future<AppUser> _syncUserToSupabase(
    User firebaseUser, {
    String? name,
    String? phoneNumber,
  }) async {
    final now = DateTime.now();
    final fromDisplay = firebaseUser.displayName?.trim();
    final isGuestLike = fromDisplay != null &&
        fromDisplay.isNotEmpty &&
        fromDisplay.toLowerCase().startsWith('guest');
    final userName = name?.trim() ??
        ((fromDisplay != null && fromDisplay.isNotEmpty && !isGuestLike)
            ? fromDisplay
            : null) ??
        firebaseUser.email?.split('@').first ??
        (firebaseUser.phoneNumber != null ? 'User' : '');
    final email = firebaseUser.email ?? '';
    final profileImage = firebaseUser.photoURL;
    final displayName = userName.isEmpty ? (email.isNotEmpty ? email.split('@').first : '') : userName;

    // Resolve the best phone number available. Prefer explicit parameter, then Firebase.
    // Only written when non-null so we never overwrite a profile-set phone with null.
    final resolvedPhone = phoneNumber ?? firebaseUser.phoneNumber;

    final row = <String, dynamic>{
      'id': firebaseUser.uid,
      'email': email,
      'name': displayName,
      'last_login': now.toIso8601String(),
      if (resolvedPhone != null && resolvedPhone.isNotEmpty)
        'phone_number': resolvedPhone,
    };

    try {
      await _supabase.from('users').upsert(
        row,
        onConflict: 'id',
      );
      final inserted = await _supabase.from('users').select().eq('id', firebaseUser.uid).maybeSingle();
      if (inserted != null) {
        debugPrint('✅ Profile synced: ${firebaseUser.uid}');
        return AppUser.fromJson(inserted);
      }
    } catch (e) {
      debugPrint('❌ Supabase user sync failed: $e');
    }

    return AppUser(
      id: firebaseUser.uid,
      email: email,
      name: userName.isEmpty ? null : userName,
      phoneNumber: firebaseUser.phoneNumber ?? phoneNumber,
      photoUrl: profileImage,
      createdAt: now,
      lastLogin: now,
    );
  }

  static Stream<User?> get authStateChanges {
    if (!isFirebaseConfigured) return const Stream.empty();
    try {
      return FirebaseAuth.instance.authStateChanges();
    } catch (e) {
      return const Stream.empty();
    }
  }

  /// Email shape check.
  ///
  /// The previous pattern capped the TLD at 4 characters, so it rejected real
  /// addresses at `.online`, `.africa` and `.company` — a validation bug that
  /// locks genuine users out before a request is ever made. This accepts any
  /// TLD of two or more letters and leaves true deliverability to the
  /// verification email, which is the only thing that can actually prove an
  /// address works.
  static bool isValidEmail(String email) {
    final e = email.trim();
    if (e.length > 254 || e.contains(' ')) return false;
    return RegExp(r"^[\w.!#$%&'*+/=?^`{|}~-]+@[\w-]+(\.[\w-]+)*\.[A-Za-z]{2,}$")
        .hasMatch(e);
  }

  /// Minimum password length. Raised from 6 to 8: six characters is below
  /// every current baseline (NIST SP 800-63B sets 8), and Help24 accounts hold
  /// escrow balances and payout numbers.
  static const int minPasswordLength = 8;

  static String? validatePassword(String password) {
    if (password.isEmpty) return 'Enter a password.';
    if (password.length < minPasswordLength) {
      return 'Use at least $minPasswordLength characters.';
    }
    if (RegExp(r'^\d+$').hasMatch(password)) {
      return 'Add letters as well as numbers.';
    }
    return null;
  }

  /// Rough strength score in 0–3, for the signup meter. Length dominates,
  /// because length is what actually resists guessing.
  static int passwordStrength(String password) {
    if (password.length < minPasswordLength) return 0;
    var score = 1;
    if (password.length >= 12) score++;
    final classes = [
      RegExp(r'[a-z]'),
      RegExp(r'[A-Z]'),
      RegExp(r'\d'),
      RegExp(r'[^\w\s]'),
    ].where((r) => r.hasMatch(password)).length;
    if (classes >= 3) score++;
    return score.clamp(0, 3);
  }
}
