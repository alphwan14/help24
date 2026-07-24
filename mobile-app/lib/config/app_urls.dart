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

  /// Where password-reset and email-verification links land. Must match the
  /// custom auth domain configured in the identity console, so the address bar
  /// during an auth hand-off reads `auth.help24.co.ke` and nothing else.
  static const String authDomain = 'auth.help24.co.ke';

  /// Deep-link continuation for reset / verify hand-offs — the "back to
  /// Help24" destination once the link has been consumed.
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
