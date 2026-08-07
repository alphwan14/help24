import 'package:flutter/foundation.dart';

/// Raised when something tries to write a `users` row that is not a person.
///
/// Not a user-facing error: reaching this means a bug in our own code, and the
/// only correct response is to refuse the write and fix the caller.
class InvalidUserRowException implements Exception {
  final String message;
  const InvalidUserRowException(this.message);
  @override
  String toString() => 'InvalidUserRowException: $message';
}

/// The single place a `public.users` row is shaped.
///
/// WHY THIS EXISTS AS A SEPARATE, PURE FUNCTION
/// --------------------------------------------
/// Three call sites write this table, and each had its own opinion about how to
/// build the row. They disagreed in exactly the way that caused the 2026-08-07
/// posting outage: some wrote `email: ''` for an account with no address, which
/// a UNIQUE index treats as a real, shared value rather than as "no address".
/// One shape, one set of rules, one thing to test.
///
/// THE INVARIANT THIS ENFORCES
/// ---------------------------
///   `public.users.id` IS the Firebase UID. Always. It is the FK target of every
///   owned row and the value every RLS policy compares against
///   `auth.jwt()->>'user_id'`.
///
/// Production once held three rows keyed by SUPABASE AUTH UUIDs instead —
/// written by a DB trigger and by the admin-invite endpoint, both since removed.
/// Each held a real person's email under the unique index, which made that
/// person's genuine row un-insertable and left them authenticated with no
/// profile and every write failing. [assertIsFirebaseUid] makes that specific
/// mistake impossible to repeat from this client: a UUID cannot be an id here.
@immutable
class UserRow {
  const UserRow._();

  /// A Supabase/Postgres UUID: 8-4-4-4-12 hex. Firebase UIDs are 28-character
  /// alphanumeric strings with no hyphens, so the two shapes cannot collide.
  static final RegExp _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  /// Refuse anything that is not a person's Firebase UID.
  static void assertIsFirebaseUid(String uid) {
    if (uid.trim().isEmpty) {
      throw const InvalidUserRowException('A users row needs an id.');
    }
    if (_uuid.hasMatch(uid.trim())) {
      throw InvalidUserRowException(
        'Refusing to write a users row keyed by a UUID ($uid). '
        'public.users.id is the Firebase UID; a Supabase Auth UUID identifies a '
        'dashboard CREDENTIAL, and linking one to a person is what '
        'user_auth_identities is for.',
      );
    }
  }

  /// Build the row to upsert.
  ///
  /// [email] is OMITTED when absent rather than written as `''`. Postgres
  /// permits many NULLs in a unique index but only one empty string, so `''`
  /// would let the first phone-only account claim "no address" for everybody.
  /// Omitting also means an update never erases an address the profile already
  /// holds — the rule `phone_number` has always followed.
  static Map<String, dynamic> build({
    required String uid,
    String? email,
    String? name,
    String? phoneNumber,
    DateTime? lastLogin,
    String? profileImage,
  }) {
    assertIsFirebaseUid(uid);
    final trimmedEmail = email?.trim() ?? '';
    final trimmedPhone = phoneNumber?.trim() ?? '';
    return <String, dynamic>{
      'id': uid.trim(),
      if (trimmedEmail.isNotEmpty) 'email': trimmedEmail,
      if (name != null) 'name': name.trim(),
      if (trimmedPhone.isNotEmpty) 'phone_number': trimmedPhone,
      if (lastLogin != null) 'last_login': lastLogin.toUtc().toIso8601String(),
      if (profileImage != null) 'profile_image': profileImage,
    };
  }
}
