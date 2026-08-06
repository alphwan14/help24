class ApiConfig {
  /// Backend origin.
  ///
  /// This defaults to the deployed backend, so a release build is correct with
  /// no build flags at all. That default matters more than the override: this
  /// was previously hardcoded to a developer's LAN address, which meant every
  /// shipped APK sent M-Pesa, payout, chat-notification and routing traffic to
  /// a machine no user can reach — over cleartext HTTP, which release builds
  /// block anyway. Payments were dead in production and nothing said so.
  ///
  /// For local development against a backend on your own machine, override at
  /// build time (compile-time constant, so it works in any build mode):
  ///
  ///   flutter run --dart-define=HELP24_API_BASE_URL=http://192.168.1.171:3000
  ///
  /// Android emulator reaches the host at 10.0.2.2, not localhost:
  ///
  ///   flutter run --dart-define=HELP24_API_BASE_URL=http://10.0.2.2:3000
  ///
  /// Mirrors the admin dashboard, which resolves the same origin from
  /// NEXT_PUBLIC_BACKEND_URL with the same production fallback.
  static const String baseUrl = String.fromEnvironment(
    'HELP24_API_BASE_URL',
    defaultValue: 'https://help24-backend.onrender.com',
  );

  /// True when [baseUrl] is not the production origin — i.e. a dart-define
  /// override is in effect. Useful for a startup log line so a build pointed at
  /// a laptop is obvious in the console instead of silently failing later.
  static const bool isOverridden =
      baseUrl != 'https://help24-backend.onrender.com';

  static const String initiatePayment  = '$baseUrl/mpesa/initiate';
  static const String paymentStatus    = '$baseUrl/mpesa/status';
  static const String releasePayout    = '$baseUrl/mpesa/release-payout';
  static const String chatNotify       = '$baseUrl/notifications/chat-message';
  /// Journey ETA / distance / polyline. Proxied because the Google Routes key
  /// is a server key — Routes is a web service and cannot be locked to an
  /// Android package + SHA-1 the way the Maps SDK key is.
  static const String routesCompute    = '$baseUrl/routes/compute';
}
