import 'format_utils.dart';

/// WHAT HELP24 PROMISES ABOUT MONEY, TOLD TO THE PERSON IT APPLIES TO.
///
/// THE BUG THIS EXISTS TO PREVENT
/// ------------------------------
/// The "Payment Protected" card on a request took no role at all. It rendered
/// for `post.type == request && post.price > 0`, which is every viewer, so a
/// provider looking at a job they might offer service on was shown the buyer's
/// script verbatim: "Pay through Help24 ... until YOU approve the completed
/// work. The provider is paid only after YOUR approval." Confirmed on the
/// physical S20+ — the same screen whose call to action reads "Offer Service"
/// told the person being paid that they were the one paying.
///
/// TRUTHFULNESS IS PART OF THE COPY, NOT A REVIEW STEP
/// ---------------------------------------------------
/// The provider's line deliberately does NOT say the money is "released
/// automatically when the job is completed". `JobsService.approve` refuses
/// anyone but the post author ("Only the post author can approve completion")
/// and there is no auto-approval timer anywhere in the backend — marking work
/// complete raises `job.completed`, and only the client's approval raises
/// `payment.payout_requested`. Promising a release on completion would promise
/// a payout the system does not make.
///
/// What IS automatic is the payout once the client approves: `approve()` emits
/// the event and `EventProcessorService` calls `releasePayout` on its own, with
/// no one to chase. That is the real reassurance, and it is the one given.
///
/// Kept out of the widget so the rule can be checked without building a screen
/// — see `test/payment_copy_test.dart`.
class PaymentCopy {
  PaymentCopy._();

  /// [isAuthor] is the client who posted the job and will pay for it.
  /// Everyone else reading a request is a potential provider.
  static String protectionTitle({required bool isAuthor}) =>
      isAuthor ? 'Pay securely through Help24' : 'You get paid securely';

  static String protectionBody({required bool isAuthor}) => isAuthor
      ? 'Pay through Help24 with M-Pesa and your money is held safely until '
          'you approve the completed work. The provider is paid only after '
          'your approval.'
      : 'Payment through Help24 is secure: the client’s money is held safely '
          'before you start. Once they approve the completed job, your M-Pesa '
          'payout is released automatically. $reviewsLine';

  /// Why a provider should want the job paid through Help24 rather than in
  /// cash. TRUE IN CODE: ReviewsService refuses a review unless the job's
  /// payment went through Help24 (a paid, paying-out or released
  /// transaction), so a cash job can never be reviewed.
  static const String reviewsLine =
      'Only jobs paid through Help24 earn reviews and count on your profile.';
}

/// Materials Advance, told to each side (backend/src/mpesa/advance.ts).
///
/// On a job of KES 10,000 or more with a verified provider, the customer may
/// let 40% go to the provider early for materials. The customer sends it, from
/// the job, when the provider is ready to buy; Help24 holds the rest until the
/// work is approved. TRUE IN CODE, and pinned by test/payment_copy_test.dart:
///   - the total is the same as paying normally (fee.ts, no extra charge);
///   - nothing is sent until the customer taps Send (never automatic);
///   - if the job fails, the customer gets back what Help24 still holds plus
///     the fee, and the advance itself cannot be pulled back once sent.
class MaterialsAdvanceCopy {
  MaterialsAdvanceCopy._();

  static String _kes(int amount) => formatPriceDisplay(amount.toDouble());

  /// Under the switch on the payment screen.
  static String checkoutLine(int advance) =>
      'Let ${_kes(advance)} (40%) go to your provider when they are ready to '
      'buy materials. You send it from the job; Help24 holds the rest until '
      'you approve the work. Same total, no extra fee.';

  static String releaseButton(int advance) => 'Send materials money · ${_kes(advance)}';

  static String confirmTitle(int advance) => 'Send ${_kes(advance)} to your provider?';

  static String confirmBody(int advance) =>
      'It goes to your provider’s M-Pesa now, for the materials on this job. '
      'Help24 keeps holding the rest until you approve the work. If the job '
      'goes wrong you get back what Help24 still holds, fee included, but '
      'money already sent for materials cannot be pulled back.';

  /// The job's status line, for the customer or the provider.
  static String? status({required String status, required int amount, required bool isClient}) {
    final kes = _kes(amount);
    switch (status) {
      case 'held':
        return isClient
            ? '$kes can go to your provider for materials when they are ready to buy.'
            : '$kes for materials is set aside. Ask the customer to send it when you are ready to buy.';
      case 'sending':
        return isClient
            ? 'Sending $kes to your provider. M-Pesa is confirming.'
            : '$kes for materials is on its way to your M-Pesa.';
      case 'paid_out':
        return isClient
            ? '$kes reached your provider for materials. The rest is held until you approve the work.'
            : '$kes for materials was sent to your M-Pesa. The rest is paid when the customer approves the work.';
      case 'frozen':
        return 'The materials money is held with the rest while the dispute is reviewed.';
      case 'cancelled':
        return 'The materials money was not sent separately; the full amount is paid in one go.';
      default:
        return null;
    }
  }
}
