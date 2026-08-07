/// Whether this device can actually show Help24 a notification.
///
/// Exists because of a real-device finding (launch-readiness-verification-report
/// §H1): on a Samsung A21s (Android 12), `dumpsys notification` showed
/// `allowNoti=false` while FirebaseMessaging reported `authorized` and the app
/// registered a token as if everything worked. FCM's authorization status
/// reflects the RUNTIME PERMISSION — which does not exist below Android 13 —
/// not the user's actual notification toggle. The OS toggle is truth; Firebase
/// is only consulted where the OS gives no answer.
library;

enum NotificationCapability {
  /// Notifications will be shown.
  enabled,

  /// The OS has notifications for this app switched off (any Android version:
  /// the settings toggle; Android 13+: also a denied runtime permission).
  /// The fix lives in system settings, not in the app.
  osBlocked,

  /// The platform channel refused (e.g. iOS permission denied, or the
  /// Android 13 runtime prompt dismissed as reported by FCM).
  denied,
}

/// Combine what FCM claims with what the OS reports.
///
/// [osEnabled] is `NotificationManagerCompat.areNotificationsEnabled()` via
/// flutter_local_notifications, or null on platforms where the question does
/// not apply (then FCM's answer stands alone).
///
/// The OS answer OUTRANKS Firebase: a blocked app is blocked no matter what
/// the token layer believes.
NotificationCapability resolveNotificationCapability({
  required bool fcmAuthorized,
  required bool? osEnabled,
}) {
  if (osEnabled == false) return NotificationCapability.osBlocked;
  if (!fcmAuthorized) return NotificationCapability.denied;
  return NotificationCapability.enabled;
}
