/// The terms a new install accepts before using Help24 (TermsAcceptanceScreen).
///
/// A plain-language summary of help24.co.ke/terms and /privacy, which stay the
/// full text. Every money sentence is TRUE IN CODE and pinned by
/// test/terms_copy_test.dart against the constants that implement it:
///   - fee: 5%, minimum KES 30, maximum KES 1,000 (payment_utils.dart, fee.ts);
///   - review window: 48 hours, then approved automatically (auto-approval.ts);
///   - a refund decided for the customer returns everything Help24 holds for
///     the job, fee included (decisions.service.ts: total_paid);
///   - Materials Advance: sent only when the customer taps Send; once sent it
///     cannot be held back (advance.ts).
/// No em dashes (plain_copy rule). Change this together with the website.
class TermsCopy {
  TermsCopy._();

  static const String title = 'Before you start';

  static const String lead =
      'Help24 connects people who need work done with the providers who do it. '
      'Please read these terms and accept them to use the app.';

  static const List<({String heading, String body})> sections = [
    (
      heading: 'What Help24 is',
      body: 'Help24 is a marketplace. Providers work for themselves, not for Help24. '
          'You agree the work and the price with your provider. You must be 18 or older to use Help24.',
    ),
    (
      heading: 'Paying through Help24',
      body: 'When you pay through the app, Help24 holds your money until you approve the work, '
          'and your provider receives the full agreed price. You pay a payment protection fee of 5% '
          'of the job (at least KES 30, never more than KES 1,000), shown before you confirm.',
    ),
    (
      heading: 'Approving the work',
      body: 'When your provider marks the job as done, you have 48 hours to approve it or open a dispute. '
          'We remind you during that time. If you do neither, the job is approved and your provider is paid.',
    ),
    (
      heading: 'If something goes wrong',
      body: 'Open a dispute in the app before the job is approved and the money stays held while our team '
          'reviews it. If the dispute is decided in your favour, you get back everything Help24 holds for '
          'the job, including the fee. If part of the work was done, the held money can be split fairly '
          'between you and the provider. Refunds are sent to you by M-Pesa.',
    ),
    (
      heading: 'Materials Advance',
      body: 'On larger jobs you can let 40% go to your provider early, for materials. Nothing is sent '
          'until you tap Send. Money already sent for materials cannot be held back, but everything '
          'Help24 still holds, fee included, comes back to you if the job fails.',
    ),
    (
      heading: 'Only payments in the app are protected',
      body: 'We cannot protect cash or M-Pesa sent directly to a provider. Keep payments in Help24: '
          'it is also the only way a job earns a review.',
    ),
    (
      heading: 'Safety and fair use',
      body: 'Use your real name and number. Do not post anything false, illegal or harmful, harass '
          'anyone, or try to get around our payment and safety systems. We may restrict or close '
          'accounts that do. Report anything unsafe from the app.',
    ),
    (
      heading: 'Your data',
      body: 'We use your details to run your account, match you with work and keep payments safe. '
          'We do not sell your personal data. The Privacy Policy explains what we collect and the '
          'rights you have over it, including getting a copy of your data or deleting your account.',
    ),
  ];

  static const String readTerms = 'Read the full Terms of Service';
  static const String readPrivacy = 'Read the Privacy Policy';

  static const String agreementNote =
      'By tapping I agree, you accept the Terms of Service and the Privacy Policy.';

  static const String accept = 'I agree';
  static const String close = 'Close Help24';
}
