/// Every user-visible Help24 address, in one place.
///
/// WHY THIS FILE IS A WHITE-LABEL BOUNDARY
/// ---------------------------------------
/// A user must never be able to tell which vendors power Help24. The moment a
/// link, a sender address or a support hint carries a provider's domain
/// (`*.firebaseapp.com`, `*.web.app`, `*.supabase.co`, `*.onrender.com`), the
/// product stops looking like a company and starts looking like someone's
/// weekend project — and it hands an attacker a free map of the stack.
///
/// This file previously pointed Terms and Privacy at `help24-24410.web.app`,
/// which leaked the hosting vendor AND the internal project id in a URL the
/// user could read in their browser's address bar. Everything now resolves
/// under help24.co.ke. Where a vendor domain still appears at runtime it is
/// documented in `_docs/AUTH_WHITE_LABEL_AUDIT.md` with the console change
/// required to remove it.
class AppUrls {
  AppUrls._();

  static const String website = 'https://help24.co.ke';
  static const String termsOfService = 'https://help24.co.ke/terms';
  static const String privacyPolicy = 'https://help24.co.ke/privacy';
  static const String helpCentre = 'https://help24.co.ke/help';
  static const String supportPortal = 'https://help24.co.ke/support';

  /// Where a reset / verify hand-off returns the user once the link has been
  /// consumed — the "you're all set" landing page, served by the website at
  /// `help24_website/app/auth/continue/`.
  ///
  /// THE ONE THING THIS CANNOT DO
  /// ----------------------------
  /// This sets the DESTINATION, not the HOST of the link itself. On Android and
  /// iOS the client SDK has no say in the action-link domain at all: it is
  /// whatever the identity console is configured to use, and the only way to
  /// change it is in the console.
  ///
  /// There used to be an `authDomain = 'auth.help24.co.ke'` constant here that
  /// looked like it controlled that. It never did — nothing read it — and a
  /// constant that names a domain it has no power over is worse than no
  /// constant, because the next reader trusts it. The console is the single
  /// source of truth for the link host; this is the single source of truth for
  /// where the user lands afterwards.
  ///
  /// Note the domain of this URL must be listed in the console's authorized
  /// domains or the whole ActionCodeSettings object is refused — see the
  /// `_continueUrlRejections` fallback in auth_service.dart, which exists
  /// solely because that listing was missing.
  static const String authContinueUrl = 'https://help24.co.ke/auth/continue';
}

/// How users reach a human. Referenced by error copy, so it lives beside the
/// URLs rather than being retyped per screen (it was previously spelled as
/// `support@help24.com` in Help Centre, Privacy and Terms — a domain Help24
/// does not own).
class AppSupport {
  AppSupport._();

  static const String email = 'support@help24.co.ke';
  static const String senderName = 'Help24 Team';
  static const String brand = 'Help24';
}
