import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/service_record.dart';

/// Service Records model contract.
///
/// These pin the two things the UI must never get wrong: that a receipt is only
/// a receipt when the backend says one exists, and that "work completed" and
/// "money settled" stay separate facts.

void main() {
  group('ReceiptResult routing', () {
    test('an unavailable payload becomes ReceiptUnavailable, not an empty receipt', () {
      final r = ReceiptResult.fromJson({
        'available': false,
        'reason': 'payment_pending',
        'message': 'Payment is still being confirmed.',
      });

      expect(r, isA<ReceiptUnavailable>());
      final u = r as ReceiptUnavailable;
      expect(u.isPending, isTrue);
      expect(u.message, 'Payment is still being confirmed.');
    });

    test('a failed payment is unavailable and is NOT reported as pending', () {
      final r = ReceiptResult.fromJson({
        'available': false,
        'reason': 'payment_failed',
        'message': 'Request cancelled by user',
      }) as ReceiptUnavailable;

      expect(r.isPending, isFalse);
      expect(r.reason, 'payment_failed');
    });

    test('a missing "available" flag is treated as unavailable, never as a receipt', () {
      // Defensive: a truncated or unexpected body must not render as a document
      // with blank money fields.
      expect(ReceiptResult.fromJson(const {}), isA<ReceiptUnavailable>());
    });
  });

  group('ServiceReceipt parsing', () {
    Map<String, dynamic> payload({bool asProvider = false}) => {
          'available': true,
          'receipt_number': 'HLP-2026-000184',
          'issued_at': '2026-09-12T10:00:00Z',
          'transaction_id': '9f8e7d6c-1234-4321-abcd-000000000001',
          'post_id': 'p1',
          'service': {
            'title': 'Bathroom Plumbing',
            'description': 'Fix the leaking sink',
            'category': 'Plumbing',
            'location': 'Kilimani, Nairobi',
          },
          'customer_name': 'Alphonse Lincoln',
          'provider_name': 'John Mwangi',
          'payment_method': 'mpesa',
          'provider_reference': asProvider ? null : 'SGH7XK2LMN',
          'provider_reference_visible': !asProvider,
          'currency': 'KES',
          'amount': 2500,
          'platform_fee': 45,
          'total_paid': 2545,
          'refunded_amount': null,
          'status': 'ESCROWED',
          'status_explanation': 'The money is held safely by Help24 until the work is approved.',
          'paid_at': '2026-09-12T09:30:00Z',
          'settled_at': null,
          'viewer_role': asProvider ? 'provider' : 'client',
        };

    test('parses the full document', () {
      final r = ReceiptResult.fromJson(payload()) as ServiceReceipt;

      expect(r.receiptNumber, 'HLP-2026-000184');
      expect(r.serviceTitle, 'Bathroom Plumbing');
      expect(r.customerName, 'Alphonse Lincoln');
      expect(r.providerName, 'John Mwangi');
      expect(r.amount, 2500);
      expect(r.platformFee, 45);
      expect(r.totalPaid, 2545);
      expect(r.status, 'ESCROWED');
      expect(r.isClient, isTrue);
    });

    test('the Help24 receipt number is never the mobile-money reference', () {
      final r = ReceiptResult.fromJson(payload()) as ServiceReceipt;
      expect(r.receiptNumber, isNot(equals(r.providerReference)));
      expect(r.receiptNumber, startsWith('HLP-'));
      expect(r.providerReference, 'SGH7XK2LMN');
    });

    test('the provider sees no mobile-money reference, and the flag says withheld', () {
      final r = ReceiptResult.fromJson(payload(asProvider: true)) as ServiceReceipt;
      expect(r.providerReference, isNull);
      expect(r.providerReferenceVisible, isFalse);
      expect(r.isClient, isFalse);
      // The provider still holds a complete work record.
      expect(r.receiptNumber, 'HLP-2026-000184');
      expect(r.amount, 2500);
    });

    test('names the payment rail for a person, and is ready for Airtel', () {
      final mpesa = ReceiptResult.fromJson(payload()) as ServiceReceipt;
      expect(mpesa.paymentMethodLabel, 'M-Pesa');

      final airtel = ReceiptResult.fromJson({
        ...payload(),
        'payment_method': 'airtel_money',
      }) as ServiceReceipt;
      expect(airtel.paymentMethodLabel, 'Airtel Money');
    });

    test('NEVER shows the word "escrow" to a user', () {
      // App-wide rule: everyday language, never "escrow" (see post_card.dart).
      // The API value stays ESCROWED on the wire; only the words a person reads
      // are translated. This guard fails if a new status is added to the API
      // and passed through to the screen untranslated.
      const apiStatuses = [
        'PAID',
        'ESCROWED',
        'RELEASED',
        'REFUNDED',
        'PARTIALLY_REFUNDED',
        'DISPUTED',
        'UNDER_REVIEW',
      ];

      for (final s in apiStatuses) {
        final r = ReceiptResult.fromJson({...payload(), 'status': s}) as ServiceReceipt;
        expect(
          r.statusLabel.toLowerCase(),
          isNot(contains('escrow')),
          reason: 'status "$s" rendered "${r.statusLabel}" — that leaks "escrow" to the UI',
        );
        // And no raw SCREAMING_SNAKE leaks through either.
        expect(r.statusLabel, isNot(contains('_')),
            reason: 'status "$s" rendered an untranslated API value');
      }
    });

    test('translates ESCROWED to the same words the rest of the app uses', () {
      final r = ReceiptResult.fromJson({...payload(), 'status': 'ESCROWED'}) as ServiceReceipt;
      // Matches the backend settlement label for in_escrow ("Payment protected").
      expect(r.statusLabel, 'PAYMENT PROTECTED');
      // The wire value is untouched.
      expect(r.status, 'ESCROWED');
    });

    test('reports a refund amount when one applies', () {
      final r = ReceiptResult.fromJson({
        ...payload(),
        'status': 'PARTIALLY_REFUNDED',
        'refunded_amount': 1000,
      }) as ServiceReceipt;
      expect(r.status, 'PARTIALLY_REFUNDED');
      expect(r.refundedAmount, 1000);
    });
  });

  group('ServiceHistory', () {
    Map<String, dynamic> record({String? completedAt, String state = 'payout_processing'}) => {
          'post_id': 'p1',
          'title': 'Laptop Repairs',
          'category': 'Electronics',
          'location': 'Nairobi',
          'post_status': 'completed',
          'archived': false,
          'viewer_role': 'provider',
          'counterparty': {'user_id': 'client1', 'name': 'Alphonse Lincoln'},
          'amount': 500,
          'total_paid': 520,
          'payment_method': 'mpesa',
          'settlement_state': state,
          'settlement_label': 'Payout processing',
          'attention_required': false,
          'receipt_available': true,
          'created_at': '2026-06-20T08:00:00Z',
          'completed_at': completedAt,
          'settled_at': null,
        };

    test('completed work is independent of settled money', () {
      final h = ServiceHistory.fromJson({
        'records': [record(completedAt: '2026-06-22T09:03:50Z')],
        'total_completed': 1,
        'completed_value': 500,
        'has_more': false,
      });

      final r = h.records.single;
      // The job is done...
      expect(r.isCompletedWork, isTrue);
      expect(h.totalCompleted, 1);
      // ...while the money is honestly still moving.
      expect(r.settlementState, 'payout_processing');
      expect(r.settledAt, isNull);
    });

    test('a record with no approved completion is not counted as completed work', () {
      final h = ServiceHistory.fromJson({
        'records': [record(completedAt: null)],
        'total_completed': 0,
        'completed_value': 0,
        'has_more': false,
      });
      expect(h.records.single.isCompletedWork, isFalse);
      expect(h.totalCompleted, 0);
    });

    test('an empty history parses without throwing', () {
      final h = ServiceHistory.fromJson(const {});
      expect(h.isEmpty, isTrue);
      expect(h.totalCompleted, 0);
      expect(h.completedValue, 0);
      expect(h.hasMore, isFalse);
    });

    test('a blank counterparty name becomes null rather than an empty row', () {
      final h = ServiceHistory.fromJson({
        'records': [
          {...record(), 'counterparty': {'user_id': 'u1', 'name': '   '}},
        ],
      });
      expect(h.records.single.counterpartyName, isNull);
    });
  });
}
