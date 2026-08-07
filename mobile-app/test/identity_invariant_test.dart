import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/services/user_row.dart';
import 'package:help24/utils/auth_error_mapper.dart';

/// THE INVARIANT THIS FILE DEFENDS
/// -------------------------------
///   One human → one Firebase account → one Firebase UID → one `public.users`
///   row → every post, application, chat, notification, review, payment and
///   escrow record they own.
///
/// It is written from a real outage. On 2026-08-07 three `public.users` rows
/// were found keyed by SUPABASE AUTH UUIDs rather than Firebase UIDs, written by
/// a DB trigger (`handle_new_auth_user`) and by the admin-invite endpoint. Each
/// held a real person's email address under a UNIQUE index, which made that
/// person's genuine Firebase-keyed row impossible to insert:
///
///   duplicate key value violates unique constraint "users_email_unique" (23505)
///
/// The client swallowed the rejection, so the account had no profile row at all
/// — and because `posts.author_user_id` is a foreign key into `users(id)`, every
/// post, edit, application and profile save failed with "We couldn't finish
/// setting up your account". Three of seventeen users were silently locked out;
/// the other fourteen were fine, which is why it read as random.
///
/// Every test below fails if any part of that can happen again.
void main() {
  group('a users row is always keyed by the Firebase UID', () {
    test('a Firebase UID is accepted', () {
      final row = UserRow.build(uid: 'bLbPkk9w2uSX8sLbgvjw2wMBOPb2');
      expect(row['id'], 'bLbPkk9w2uSX8sLbgvjw2wMBOPb2');
    });

    test('a Supabase Auth UUID is REFUSED — this is the ghost row', () {
      // The three real ids that caused the outage.
      for (final uuid in const [
        '0f192cb2-2227-488a-8cd7-ff3876cb7aa7',
        '358633b8-57fa-4c81-a2aa-74693beb1fbf',
        '0fa846f8-7e84-4870-ae4e-9e1d6f82b367',
      ]) {
        expect(
          () => UserRow.build(uid: uuid, email: 'someone@example.com'),
          throwsA(isA<InvalidUserRowException>()),
          reason: uuid,
        );
      }
    });

    test('an uppercase UUID is refused too', () {
      expect(
        () => UserRow.build(uid: '0F192CB2-2227-488A-8CD7-FF3876CB7AA7'),
        throwsA(isA<InvalidUserRowException>()),
      );
    });

    test('an empty id is refused', () {
      expect(() => UserRow.build(uid: ''), throwsA(isA<InvalidUserRowException>()));
      expect(() => UserRow.build(uid: '   '), throwsA(isA<InvalidUserRowException>()));
    });
  });

  group('email is omitted, never written as an empty string', () {
    // `users.email` is UNIQUE. Postgres permits many NULLs but exactly ONE
    // empty string — so '' is not "no address", it is a single shared address
    // that the first phone-only account would claim for everybody. The second
    // phone-only sign-up would then fail with 23505 and be unable to post.

    test('a null email produces no email key', () {
      expect(UserRow.build(uid: 'uid1', email: null).containsKey('email'), isFalse);
    });

    test('an empty email produces no email key', () {
      expect(UserRow.build(uid: 'uid1', email: '').containsKey('email'), isFalse);
    });

    test('a whitespace-only email produces no email key', () {
      expect(UserRow.build(uid: 'uid1', email: '   ').containsKey('email'), isFalse);
    });

    test('a real email is written, trimmed', () {
      expect(UserRow.build(uid: 'uid1', email: '  a@b.com ')['email'], 'a@b.com');
    });

    test('case is preserved — the database index owns case-insensitivity', () {
      // Lower-casing here would silently rewrite what the user typed. The
      // uniqueness rule lives in the partial index on lower(email); this layer
      // must not duplicate it, or the two can disagree.
      expect(UserRow.build(uid: 'uid1', email: 'Karen@Gmail.com')['email'],
          'Karen@Gmail.com');
    });

    test('phone-only accounts build a valid row with no email at all', () {
      final row = UserRow.build(uid: 'phoneUid1', phoneNumber: '+254712345678');
      expect(row.containsKey('email'), isFalse);
      expect(row['phone_number'], '+254712345678');
      expect(row['id'], 'phoneUid1');
    });

    test('two phone-only accounts build rows that cannot collide', () {
      final a = UserRow.build(uid: 'phoneUidA', phoneNumber: '+254711111111');
      final b = UserRow.build(uid: 'phoneUidB', phoneNumber: '+254722222222');
      expect(a.containsKey('email'), isFalse);
      expect(b.containsKey('email'), isFalse);
      expect(a['id'], isNot(b['id']));
    });
  });

  group('an absent value never erases a stored one', () {
    // These rows are UPSERTed, so a key that is present overwrites. A missing
    // phone or email must therefore be absent from the map rather than null,
    // or signing in on a device that knows less would wipe the profile.
    test('no phone key when the phone is unknown', () {
      expect(UserRow.build(uid: 'u', phoneNumber: null).containsKey('phone_number'), isFalse);
      expect(UserRow.build(uid: 'u', phoneNumber: '').containsKey('phone_number'), isFalse);
    });

    test('no name key when the name is unknown', () {
      expect(UserRow.build(uid: 'u', name: null).containsKey('name'), isFalse);
    });
  });

  group('a rejected credential never sends a Google user to reset a password', () {
    // An account created with Google HAS no password, so a reset cannot
    // succeed: the email arrives and answers a question the user was not
    // asking. With email-enumeration protection on (which Help24 keeps on
    // deliberately), the provider collapses "wrong password", "no such user"
    // and "this account has no password" into one code, so the copy must offer
    // the door the user cannot otherwise reach.
    test('invalid-credential offers the Google door', () {
      for (final code in const [
        'invalid-credential',
        'wrong-password',
        'invalid-login-credentials',
      ]) {
        final f = AuthErrorMapper.toFailure(FirebaseAuthException(code: code));
        expect(f.recovery, AuthRecovery.useGoogle, reason: code);
      }
    });

    test('an already-registered email routes to sign-in, not to a second account', () {
      final f = AuthErrorMapper.toFailure(
        FirebaseAuthException(code: 'email-already-in-use'),
        flow: AuthFlow.signUp,
      );
      expect(f.recovery, AuthRecovery.signIn);
      // Whatever it says, it must never read as "make another one".
      expect(f.message.toLowerCase(), isNot(contains('create')));
    });

    test('linking failures never tell a signed-in user to sign in again', () {
      for (final code in const [
        'provider-already-linked',
        'credential-already-in-use',
        'email-already-in-use',
      ]) {
        final f = AuthErrorMapper.toFailure(
          FirebaseAuthException(code: code),
          flow: AuthFlow.linkMethod,
        );
        expect(f.recovery, AuthRecovery.none, reason: code);
      }
    });
  });
}
