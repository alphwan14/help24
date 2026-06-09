class ApiConfig {
  static const String baseUrl = 'https://help24-backend.onrender.com';

  static const String initiatePayment  = '$baseUrl/mpesa/initiate';
  static const String paymentStatus    = '$baseUrl/mpesa/status';
  static const String releasePayout    = '$baseUrl/mpesa/release-payout';
  static const String chatNotify       = '$baseUrl/notifications/chat-message';
}
