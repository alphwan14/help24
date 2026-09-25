import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/post_ownership.dart';

/// WHAT BECAME OF AN APPLICATION IS DERIVED, NOT STORED.
///
/// WHY THIS IS A TEST AND NOT A COLUMN
/// -----------------------------------
/// The `applications` row records that you applied, when, and for how much.
/// It records nothing about the decision. The decision lives on the POST —
/// `status` plus `selected_provider_id` — which is the same pair the owner's
/// applicant screen, the job lifecycle and the escrow flow all read.
///
/// Adding an `outcome` column would have been a second copy of that, and a
/// second copy can disagree: an applicant would be told they were hired by a
/// row that the payment flow had never heard of. So the applied list derives
/// it, and these cases pin the derivation.
///
/// THE RULE THAT MATTERS MOST
/// --------------------------
/// We only ever say "Not selected" when the post NAMES a different provider.
/// A post that merely left 'open' — cancelled, archived, or assigned by some
/// path that did not stamp the id — is reported as closed. Telling a provider
/// they were rejected when nobody rejected them is the one error on this
/// screen that is worse than saying nothing.
void main() {
  const me = 'user_me';
  const someoneElse = 'user_other';

  ApplicationOutcome outcome({
    required String status,
    String? selected,
    String viewer = me,
  }) =>
      applicationOutcomeFor(
        status: status,
        selectedProviderUserId: selected,
        viewerUserId: viewer,
      );

  group('while nobody has been chosen', () {
    test('an open post is awaiting a decision', () {
      expect(outcome(status: 'open'), ApplicationOutcome.pending);
    });

    test('an empty status is treated as open, not as a closed job', () {
      // Legacy rows predate the status column. The generous reading is the
      // safe one: it keeps a live job on the list instead of burying it.
      expect(outcome(status: ''), ApplicationOutcome.pending);
    });
  });

  group('when the viewer was chosen', () {
    test('assigned means hired', () {
      expect(outcome(status: 'assigned', selected: me),
          ApplicationOutcome.hired);
    });

    test('completed means completed', () {
      expect(outcome(status: 'completed', selected: me),
          ApplicationOutcome.completed);
    });

    test('disputed is surfaced, never softened into completed', () {
      expect(outcome(status: 'disputed', selected: me),
          ApplicationOutcome.disputed);
    });

    test('an unknown status on a post naming the viewer still reads as hired',
        () {
      // Being named IS the outcome the applicant cares about. A status this
      // build does not recognise must not erase it.
      expect(outcome(status: 'some_future_state', selected: me),
          ApplicationOutcome.hired);
    });
  });

  group('when somebody else was chosen', () {
    test('the post naming another provider is the only rejection signal', () {
      expect(outcome(status: 'assigned', selected: someoneElse),
          ApplicationOutcome.notSelected);
    });

    test('a completed job that went to someone else is not selected', () {
      expect(outcome(status: 'completed', selected: someoneElse),
          ApplicationOutcome.notSelected);
    });
  });

  group('closed, which is not the same as rejected', () {
    test('cancelled with nobody named is closed', () {
      expect(outcome(status: 'cancelled'), ApplicationOutcome.closed);
    });

    test('assigned with nobody named is closed, never "not selected"', () {
      expect(outcome(status: 'assigned', selected: null),
          ApplicationOutcome.closed,
          reason: 'nothing here says anyone was preferred over the viewer');
    });

    test('an empty selected id is the same as none', () {
      expect(
          outcome(status: 'assigned', selected: ''), ApplicationOutcome.closed);
    });
  });

  group('empty ids never match', () {
    test('a signed-out viewer is not hired by a post with no chosen provider',
        () {
      // The bug this mirrors is the one isListingOwner exists to prevent:
      // '' == '' handing a stranger somebody else's outcome.
      expect(outcome(status: 'assigned', selected: '', viewer: ''),
          ApplicationOutcome.closed);
    });
  });

  group('every outcome has a label and a liveness', () {
    test('no outcome can ship without one', () {
      for (final o in ApplicationOutcome.values) {
        expect(applicationOutcomeLabel(o), isNotEmpty, reason: '$o has no label');
        // Exhaustive switches: this would not compile if a value were missing,
        // which is the point — the call is the assertion.
        applicationOutcomeIsLive(o);
      }
    });

    test('live means the applicant still has something to do', () {
      expect(applicationOutcomeIsLive(ApplicationOutcome.pending), isTrue);
      expect(applicationOutcomeIsLive(ApplicationOutcome.hired), isTrue);
      expect(applicationOutcomeIsLive(ApplicationOutcome.disputed), isTrue,
          reason: 'a dispute is the most urgent thing on the list');
      expect(applicationOutcomeIsLive(ApplicationOutcome.completed), isFalse);
      expect(applicationOutcomeIsLive(ApplicationOutcome.notSelected), isFalse);
      expect(applicationOutcomeIsLive(ApplicationOutcome.closed), isFalse);
    });
  });
}
