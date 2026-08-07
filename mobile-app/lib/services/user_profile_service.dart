import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/post_model.dart';
import '../models/user_model.dart';
import '../utils/phone_utils.dart';
import 'adaptive_poll.dart';
import 'post_service.dart';
import 'storage_service.dart';
import 'supabase_auth_bridge.dart';
import 'user_row.dart';

/// User profile: Supabase `users` table + Supabase Storage bucket `profiles` for avatar.
/// No Firestore or Firebase Storage. id = Firebase Auth UID (synced to Supabase on login).
class UserProfileService {
  static SupabaseClient get _client => Supabase.instance.client;

  static bool get _isAvailable => true;

  /// The ONE way this class writes to `public.users`.
  ///
  /// WHY EVERY WRITE GOES THROUGH HERE
  /// ---------------------------------
  /// `users` UPDATE is owner-scoped in the database: the policy compares
  /// `id` against `auth.jwt() ->> 'user_id'`, which only exists once the
  /// Firebase token has been exchanged for a Supabase JWT. Without that
  /// exchange the request travels as `anon` and is refused — correctly, because
  /// an anonymous caller genuinely cannot prove it owns the row.
  ///
  /// Thirteen call sites used to issue this update directly, none of which
  /// established the session first. Chat, applications and reports all did; the
  /// identity table did not. Rather than add the same line in thirteen places
  /// and rely on the fourteenth remembering, the session is a precondition of
  /// the write itself.
  ///
  /// Refuses rather than attempting an unprovable write: an update that runs as
  /// `anon` does not error loudly, it silently matches zero rows, which is how a
  /// "saved" profile change quietly fails to save.
  static Future<void> _updateUser(String uid, Map<String, dynamic> changes) async {
    final ok = await SupabaseAuthBridge.ensureSessionForWriteAsync();
    if (!ok) {
      throw UserProfileException(
        "We couldn't confirm it's you. Check your connection and try again.",
      );
    }
    await _client.from('users').update(changes).eq('id', uid);
  }

  /// Create or ensure user row in Supabase on signup. Call after Firebase Auth user is created.
  static Future<void> createUserOnSignup({
    required String uid,
    required String email,
    String? name,
    String? phone,
  }) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      // Despite the name, this runs on every phone sign-in, not only the first
      // — so for a RETURNING user the upsert resolves to an UPDATE, which is
      // owner-scoped. Establish the session first or a returning phone user's
      // sign-in would start failing. Best-effort: a first-time INSERT is still
      // permitted anonymously, so a failed exchange must not block sign-up.
      await SupabaseAuthBridge.ensureSessionForWriteAsync();
      final displayName = name?.trim() ?? (email.isNotEmpty ? email.split('@').first : '');
      await _client.from('users').upsert(
        UserRow.build(
          uid: uid,
          email: email,
          name: displayName,
          phoneNumber: phone,
          profileImage: '',
        ),
        onConflict: 'id',
      );
      debugPrint('✅ UserProfileService: created/updated user $uid in Supabase');
    } catch (e) {
      // BEST-EFFORT, DELIBERATELY — this no longer rethrows.
      //
      // Two reasons, and the second is the one that matters after the
      // owner-only UPDATE policy. First: rethrowing here made `signUp` report
      // "we couldn't create your account" AFTER the identity account had
      // already been created, stranding a Firebase user with no profile and no
      // way back. Second: this runs on EVERY phone sign-in, so for a returning
      // user the upsert is an UPDATE — and if the token exchange had not
      // completed, that update is (correctly) refused, which would have turned
      // a slow network into a failed sign-in.
      //
      // Provisioning is not the guarantee. `AuthService.ensureCurrentUserInSupabase`
      // is: it runs before every owned write, verifies the row, and refuses
      // with the real reason if it is genuinely absent. Signing in is allowed to
      // be optimistic because the write path is not.
      debugPrint('[PROFILE] createUserOnSignup deferred for $uid: ${e.runtimeType}');
    }
  }

  /// Best-effort repair-on-read: create the profile row if it is missing.
  ///
  /// NEVER THROWS. This is called fire-and-forget from a post-frame callback in
  /// the profile screen, where nothing can catch it — the `rethrow` this used
  /// to end with surfaced as `Unhandled Exception` in production logs, twice
  /// over: once for the `users_email_unique` collision that caused the
  /// karenbrina98 outage, and once for a benign `users_pkey` conflict when the
  /// sign-in sync simply won the race and created the row first.
  ///
  /// A repair that loses its race has nothing to report: the row exists, which
  /// is the entire point of the call. A repair that fails for a real reason is
  /// logged here and refused properly at the write path by
  /// [AuthService.ensureCurrentUserInSupabase], which is where a user can
  /// actually be told.
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
      await _client.from('users').insert(UserRow.build(
        uid: uid,
        email: email,
        name: displayName,
        phoneNumber: phone,
        profileImage: '',
      ));
      debugPrint('UserProfileService: ensured user $uid in Supabase');
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        // Lost the race with the sign-in sync. The row is there; that is a
        // success by any reading of what this method promises.
        debugPrint('[PROFILE] ensureProfileDoc: row already present for $uid');
        return;
      }
      debugPrint('[PROFILE] ensureProfileDoc ($uid) rejected: ${e.code} ${e.message}');
    } catch (e) {
      debugPrint('[PROFILE] ensureProfileDoc ($uid) failed: ${e.runtimeType}');
    }
  }

  /// Save M-Pesa phone number to user profile. Normalizes to `254XXXXXXXXX` before saving.
  static Future<void> saveMpesaPhone(String uid, String phone) async {
    if (!_isAvailable || uid.isEmpty || phone.isEmpty) return;
    final normalized = normalizeKenyanNumber(phone.trim());
    if (normalized == null) {
      throw UserProfileException(
        'Invalid phone number format. Use 254XXXXXXXXX (e.g. 254712345678).',
      );
    }
    debugPrint('[UserProfileService] saveMpesaPhone uid=$uid normalized=$normalized');
    try {
      await _updateUser(uid, {'phone_number': normalized});
      debugPrint('✅ UserProfileService: saved phone_number=$normalized for $uid');
    } catch (e) {
      debugPrint('UserProfileService saveMpesaPhone: $e');
      rethrow;
    }
  }

  /// Fetch just the phone_number for a user. Returns null if not set.
  static Future<String?> getMpesaPhone(String uid) async {
    if (!_isAvailable || uid.isEmpty) return null;
    try {
      final r = await _client.from('users').select('phone_number').eq('id', uid).maybeSingle();
      return r?['phone_number']?.toString();
    } catch (e) {
      debugPrint('UserProfileService getMpesaPhone: $e');
      return null;
    }
  }

  /// Set online status and last_seen in Supabase users.
  static Future<void> setOnline(String uid, bool isOnline) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      await _updateUser(uid, {
        'is_online': isOnline,
        'last_seen': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('UserProfileService setOnline: $e');
    }
  }

  /// Stream of user profile from Supabase (polling every 15s, no Realtime).
  static Stream<UserModel?> watchUser(String? uid) {
    if (!_isAvailable || uid == null || uid.isEmpty) return Stream.value(null);

    final controller = StreamController<UserModel?>.broadcast();
    var hasDelivered = false;

    Future<void> fetch() async {
      try {
        final r = await _client.from('users').select().eq('id', uid).maybeSingle();
        if (controller.isClosed) return;
        hasDelivered = true;
        if (r != null) {
          controller.add(UserModel.fromSupabase(r as Map<String, dynamic>));
        } else {
          controller.add(null);
        }
      } catch (e) {
        debugPrint('UserProfileService watchUser fetch: $e');
        if (controller.isClosed) return;
        // An error is not an emptiness — the same rule the conversation stream
        // follows. `add(null)` here means "there is no such user", and emitting
        // it on a failed fetch blanked a profile that was on screen a moment
        // earlier. Once we have delivered a real answer, a failure delivers
        // nothing and the last known profile stands.
        if (!hasDelivered) controller.addError(e);
      }
    }

    final poll = AdaptivePoll(
      interval: const Duration(seconds: 15),
      onTick: fetch,
      debugLabel: 'watchUser',
    );
    poll.start();
    controller.onCancel = poll.dispose;

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

  /// Update profile in Supabase users. Saves profile_image URL (from Supabase Storage), profession.
  ///
  /// Prefer the focused writers below ([updateName], [updateProfession],
  /// [updateBio]) for user-initiated edits — the Professional Profile edits one
  /// field at a time, so a multi-field PATCH would send unchanged values back
  /// and, for `name`, would trip the change-guard trigger on a no-op save.
  static Future<void> updateProfile({
    required String uid,
    String? name,
    String? bio,
    String? profession,
    String? profileImage,
  }) async {
    if (!_isAvailable || uid.isEmpty) return;
    try {
      final updates = <String, dynamic>{};
      if (name != null) updates['name'] = name;
      if (bio != null) updates['bio'] = bio;
      if (profession != null) updates['profession'] = profession;
      if (profileImage != null) {
        updates['profile_image'] = profileImage;
        updates['avatar_url'] = profileImage;
      }
      if (updates.isEmpty) return;
      await _updateUser(uid, updates);
    } catch (e) {
      debugPrint('UserProfileService updateProfile ($uid): $e');
      rethrow;
    }
  }

  /// Save a new display name.
  ///
  /// [name] MUST already be the normalized value from `NameValidator.check` —
  /// this method does not re-validate shape, it owns the WRITE. The 30-day
  /// cooldown is enforced by the database trigger (migration 087), not here;
  /// a rejection surfaces as a PostgrestException carrying the
  /// `HELP24_NAME_COOLDOWN` marker, which ErrorMapper turns into a rule-shaped
  /// message. Callers should still check the cooldown client-side first so the
  /// user is told before typing, not after saving.
  static Future<void> updateName({required String uid, required String name}) async {
    if (!_isAvailable || uid.isEmpty) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw UserProfileException('Enter your name.');
    }
    await _updateUser(uid, {'name': trimmed});
    debugPrint('[PROFILE] name updated for $uid');
  }

  /// Save the profession KEY (`professions.id`, e.g. `electrician`).
  ///
  /// Writing the key — not a display label — is what makes provider search,
  /// filtering and matching possible. Pass an empty string to clear.
  static Future<void> updateProfession({
    required String uid,
    required String professionId,
  }) async {
    if (!_isAvailable || uid.isEmpty) return;
    await _updateUser(uid, {'profession': professionId.trim()});
    debugPrint('[PROFILE] profession set to "${professionId.trim()}" for $uid');
  }

  /// Save the bio. Trimmed; empty clears it.
  static Future<void> updateBio({required String uid, required String bio}) async {
    if (!_isAvailable || uid.isEmpty) return;
    await _updateUser(uid, {'bio': bio.trim()});
  }

  /// The publicly visible profile of ANY user — powers the provider profile
  /// screen and the "View Profile" action on applicant cards.
  ///
  /// Reads the same `users` row the feed already joins for author name/avatar,
  /// so it needs no migration and no new grant. When the users-table PII
  /// lockdown lands, this is the ONE call site to repoint at `public_profiles`
  /// (which will need profession/bio/created_at added to the view).
  static Future<UserModel?> getPublicProfile(String userId) async {
    if (!_isAvailable || userId.isEmpty) return null;
    try {
      final row = await _client
          .from('users')
          .select('id, name, email, profile_image, avatar_url, bio, profession, created_at')
          .eq('id', userId)
          .maybeSingle();
      if (row == null) return null;
      // Email is intentionally NOT surfaced by the provider profile UI; it is
      // selected only because UserModel carries it for the owner's own screen.
      return UserModel.fromSupabase(row as Map<String, dynamic>);
    } catch (e) {
      debugPrint('UserProfileService getPublicProfile ($userId): $e');
      return null;
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
      await _updateUser(uid, {
        'profile_image': urlWithCacheBuster,
        'avatar_url': urlWithCacheBuster,
      });
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
      await _updateUser(uid, {'notifications_enabled': enabled});
    } catch (e) {
      debugPrint('UserProfileService setNotificationsEnabled: $e');
    }
  }

  /// Upsert FCM token and remove all stale tokens for this user+platform.
  ///
  /// Runs on every app launch. One device = one valid token; extras accumulate
  /// silently from reinstalls or FCM rotations. The backend sends to ALL tokens
  /// for a user, so extras cause duplicate pushes. Upsert first (no zero-token
  /// window), then wipe every other token for this platform.
  static Future<void> addFcmToken(String uid, String token) async {
    if (!_isAvailable || uid.isEmpty || token.isEmpty) return;
    try {
      final platform = _detectPlatform();

      // Step 1: upsert current token so user always has at least one valid token.
      debugPrint('[FCM][TOKEN_SAVE] upsert token for uid=$uid platform=$platform');
      await _client.from('fcm_tokens').upsert(
        {
          'user_id':    uid,
          'token':      token,
          'platform':   platform,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'token',
      );

      // Step 2: delete every OTHER token for this user+platform.
      // Runs unconditionally so pre-existing stale tokens are always purged,
      // even if this is the first run after a reinstall or the fix deployment.
      try {
        await _client
            .from('fcm_tokens')
            .delete()
            .eq('user_id', uid)
            .eq('platform', platform)
            .neq('token', token);
        debugPrint('[FCM][TOKEN_CLEANUP] stale tokens removed for uid=$uid platform=$platform');
      } catch (cleanupErr) {
        debugPrint('[FCM][TOKEN_CLEANUP][WARN] $cleanupErr');
      }

      debugPrint('[FCM][TOKEN_SAVE] done uid=$uid');
    } catch (e) {
      debugPrint('[FCM][TOKEN_ERROR] addFcmToken: $e');
    }
  }

  static String _detectPlatform() {
    // Using Platform detection via dart:io would require an import; keep it
    // simple with the flutter foundation default.
    if (defaultTargetPlatform == TargetPlatform.iOS) return 'ios';
    if (defaultTargetPlatform == TargetPlatform.android) return 'android';
    return 'web';
  }

  static Future<void> removeFcmToken(String uid, String token) async {
    if (!_isAvailable || uid.isEmpty || token.isEmpty) return;
    try {
      debugPrint('[FCM][TOKEN_SAVE] removing token for uid=$uid');
      await _client
          .from('fcm_tokens')
          .delete()
          .eq('user_id', uid)
          .eq('token', token);
      debugPrint('[FCM][TOKEN_SAVE] token removed for uid=$uid');
    } catch (e) {
      debugPrint('[FCM][TOKEN_ERROR] removeFcmToken: $e');
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
      await _updateUser(uid, {'language': languageCode});
    } catch (e) {
      debugPrint('UserProfileService setLanguage: $e');
    }
  }

  /// Count of non-job posts authored by this user (the profile "Posts" stat).
  ///
  /// Reputation (rating / reviews / completed jobs / tier) is NO LONGER read from
  /// users.average_rating / users.total_reviews / users.completed_jobs_count —
  /// those orphan columns are dead. Reputation is served exclusively by the
  /// backend reputation endpoint (GET /reputation/:id) via ReputationService.
  /// Count of the user's live (non-archived) posts — requests, offers AND
  /// job posts. Server-side count: no rows are downloaded (the old version
  /// fetched up to 10k IDs to count them, and arbitrarily excluded jobs).
  static Future<int> getAuthoredPostsCount(String uid) async {
    if (!_isAvailable || uid.isEmpty) return 0;
    try {
      final count = await _client
          .from('posts')
          .count(CountOption.exact)
          .eq('author_user_id', uid)
          .filter('archived_at', 'is', null);
      return count;
    } catch (e) {
      debugPrint('UserProfileService getAuthoredPostsCount: $e');
      return 0;
    }
  }

  /// The user's own posts (all types, non-archived, newest first) with the
  /// same joins the feed uses so PostCard renders identically. Powers the
  /// profile's My Posts screen. Throws on failure — the screen shows a real
  /// error state instead of silently rendering "no posts".
  /// Delegates to [PostService.getMyPosts] — the single "my listings" query.
  ///
  /// This used to be a second, hand-written copy of the same read, including a
  /// sixth transcription of the feed select string, and it disagreed with
  /// `getMyPosts` about whether job posts count as your posts. Two queries
  /// answering one question is how a user's own job became invisible from one
  /// entry point and visible from another.
  static Future<List<PostModel>> getAuthoredPosts(String uid, {int limit = 100}) async {
    if (!_isAvailable || uid.isEmpty) return const [];
    return PostService.getMyPosts(uid, limit: limit);
  }

  // REMOVED (Phase 3.2B): incrementCompletedJobsCount — a client-side "current + 1"
  // counter that wrote users.completed_jobs_count. Reputation is now derived
  // server-side from canonical data (provider_reputation via
  // fn_recompute_provider_reputation); there is exactly one authority and no
  // client-maintained counters.

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
      await _updateUser(uid, {
        'tos_accepted_at': DateTime.now().toUtc().toIso8601String(),
      });
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
    var hasDelivered = false;

    Future<void> fetch() async {
      try {
        final r = await _client.from('users').select('notifications_enabled, language').eq('id', uid).maybeSingle();
        if (controller.isClosed) return;
        final enabled = r?['notifications_enabled'] as bool? ?? true;
        final lang = r?['language']?.toString();
        final language = (lang == 'sw' || lang == 'en') ? lang! : 'en';
        hasDelivered = true;
        controller.add((notificationsEnabled: enabled, language: language));
      } catch (e) {
        if (controller.isClosed) return;
        // Publishing the DEFAULTS on failure is worse than publishing nothing:
        // a user who had switched notifications off would watch the toggle flip
        // back on because a poll timed out. Defaults are for a first load with
        // no answer, not for an answer we failed to get.
        if (!hasDelivered) {
          controller.add((notificationsEnabled: true, language: 'en'));
        }
      }
    }

    final poll = AdaptivePoll(
      interval: const Duration(seconds: 15),
      onTick: fetch,
      debugLabel: 'watchUserPrefs',
    );
    poll.start();
    controller.onCancel = poll.dispose;
    return controller.stream;
  }
}

class UserProfileException implements Exception {
  final String message;
  UserProfileException(this.message);
  @override
  String toString() => 'UserProfileException: $message';
}
