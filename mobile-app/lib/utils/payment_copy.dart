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
          'payout is released automatically.';
}
