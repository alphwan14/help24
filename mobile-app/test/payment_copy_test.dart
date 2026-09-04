import 'package:flutter_test/flutter_test.dart';
import 'package:help24/utils/payment_copy.dart';

/// THE TWO SIDES OF A JOB ARE NOT DOING THE SAME THING.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// Reproduced on the physical S20+, signed in as Alphonse Lincoln, opening
/// Lincoln Waniala's "Looking for light transport services" (request, KES
/// 1,200). The call to action read "Offer Service" — so the reader is the
/// PROVIDER — and directly above it the card said:
///
///   "Pay through Help24 with M-Pesa and your money is held safely until you
///    approve the completed work. The provider is paid only after your
///    approval."
///
/// The person being paid was handed the payer's script. `_PaymentProtectionCard`
/// took `isDark` and nothing else; its only condition was
/// `post.type == request && post.price > 0`, which every viewer satisfies.
///
/// AND THE COPY MUST STAY TRUE
/// ---------------------------
/// Reassuring a provider is easy; reassuring them with something the backend
/// does not do is a promise about their money. `JobsService.approve` throws
/// `ForbiddenException('Only the post author can approve completion.')` and no
/// auto-approval timer exists — so "released automatically when the job is
/// completed" would be false. The payout IS automatic once the client approves
/// (`approve()` emits `payment.payout_requested`; `EventProcessorService` calls
/// `releasePayout`), and that is what the copy may claim.
void main() {
  const client = true;
  const provider = false;

  group('the client is told to pay', () {
    test('the title names paying', () {
      expect(
        PaymentCopy.protectionTitle(isAuthor: client).toLowerCase(),
        contains('pay'),
      );
      expect(PaymentCopy.protectionTitle(isAuthor: client), 'Pay securely through Help24');
    });

    test('the body puts the approval in their hands', () {
      final body = PaymentCopy.protectionBody(isAuthor: client).toLowerCase();
      expect(body, contains('pay through help24'));
      expect(body, contains('you approve'));
    });
  });

  group('the provider is told they get paid', () {
    test('the two sides never read the same', () {
      expect(
        PaymentCopy.protectionTitle(isAuthor: provider),
        isNot(PaymentCopy.protectionTitle(isAuthor: client)),
      );
      expect(
        PaymentCopy.protectionBody(isAuthor: provider),
        isNot(PaymentCopy.protectionBody(isAuthor: client)),
      );
    });

    test('the provider is never instructed to pay', () {
      final body = PaymentCopy.protectionBody(isAuthor: provider).toLowerCase();
      // The exact instruction the device showed them.
      expect(body, isNot(contains('pay through help24 with m-pesa')));
      expect(body, isNot(contains('your money is held')));
    });

    test('the provider is told the payment is secure', () {
      final body = PaymentCopy.protectionBody(isAuthor: provider).toLowerCase();
      expect(body, contains('secure'));
      expect(body, contains('held safely'));
    });

    test('the provider is told the payout reaches them automatically', () {
      final body = PaymentCopy.protectionBody(isAuthor: provider).toLowerCase();
      expect(body, contains('payout'));
      expect(body, contains('automatically'));
    });
  });

  group('TRUTHFULNESS — the copy may not outrun the backend', () {
    test('release is attributed to the client approving, not to completion', () {
      final body = PaymentCopy.protectionBody(isAuthor: provider).toLowerCase();
      // Only `JobsService.approve` — post author only — reaches releasePayout.
      // The trigger must be named, or "automatically" reads as "on completion".
      expect(body, contains('approve'));
    });

    test('completing the work is never stated as the trigger for release', () {
      final body = PaymentCopy.protectionBody(isAuthor: provider).toLowerCase();
      // The phrasings that would promise a payout the system does not make.
      expect(body, isNot(contains('released when the job is completed')));
      expect(body, isNot(contains('released automatically when the job is completed')));
      expect(body, isNot(contains('automatically released when the job is completed')));
      expect(body, isNot(contains('once the job is complete')));
    });
  });
}
