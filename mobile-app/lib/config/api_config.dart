class ApiConfig {
  static const String baseUrl = 'http://192.168.1.171:3000';

  static const String initiatePayment  = '$baseUrl/mpesa/initiate';
  static const String paymentStatus    = '$baseUrl/mpesa/status';
  static const String releasePayout    = '$baseUrl/mpesa/release-payout';
  static const String chatNotify       = '$baseUrl/notifications/chat-message';
  /// Journey ETA / distance / polyline. Proxied because the Google Routes key
  /// is a server key — Routes is a web service and cannot be locked to an
  /// Android package + SHA-1 the way the Maps SDK key is.
  static const String routesCompute    = '$baseUrl/routes/compute';
}
