/// Models for the payout-destination onboarding flow.
///
/// Mirrors the backend's owner-facing shape from
/// `GET /payout-destinations` — see backend/src/payouts/payout-onboarding.service.ts
/// (`OwnedDestination`). States are hand-mapped with an `unknown` fallback,
/// matching the CampaignStatus house style.
library;

enum PayoutDestinationStatus { pending, active, retired, unknown }

PayoutDestinationStatus payoutDestinationStatusFromString(String? value) {
  switch (value) {
    case 'pending':
      return PayoutDestinationStatus.pending;
    case 'active':
      return PayoutDestinationStatus.active;
    case 'retired':
      return PayoutDestinationStatus.retired;
    default:
      return PayoutDestinationStatus.unknown;
  }
}

extension PayoutDestinationStatusX on PayoutDestinationStatus {
  String get displayLabel {
    switch (this) {
      case PayoutDestinationStatus.pending:
        return 'Awaiting verification';
      case PayoutDestinationStatus.active:
        return 'Verified';
      case PayoutDestinationStatus.retired:
        return 'Retired';
      case PayoutDestinationStatus.unknown:
        return 'Unknown';
    }
  }
}

/// The live OTP challenge attached to a pending destination.
class PayoutChallenge {
  final String verificationId;
  final DateTime? expiresAt;
  final DateTime? resendAvailableAt;
  final int attempts;
  final int maxAttempts;

  const PayoutChallenge({
    required this.verificationId,
    required this.expiresAt,
    required this.resendAvailableAt,
    required this.attempts,
    required this.maxAttempts,
  });

  factory PayoutChallenge.fromJson(Map<String, dynamic> json) => PayoutChallenge(
        verificationId: json['verification_id']?.toString() ?? '',
        expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
        resendAvailableAt:
            DateTime.tryParse(json['resend_available_at']?.toString() ?? ''),
        attempts: json['attempts'] is num ? (json['attempts'] as num).toInt() : 0,
        maxAttempts:
            json['max_attempts'] is num ? (json['max_attempts'] as num).toInt() : 5,
      );
}

class PayoutDestination {
  final String id;
  final String channel;
  final String destination;
  final PayoutDestinationStatus status;
  final bool isDefault;
  final String? verificationMethod;
  final DateTime? verifiedAt;
  final DateTime? createdAt;
  final PayoutChallenge? verification;

  const PayoutDestination({
    required this.id,
    required this.channel,
    required this.destination,
    required this.status,
    required this.isDefault,
    this.verificationMethod,
    this.verifiedAt,
    this.createdAt,
    this.verification,
  });

  factory PayoutDestination.fromJson(Map<String, dynamic> json) =>
      PayoutDestination(
        id: json['id']?.toString() ?? '',
        channel: json['channel']?.toString() ?? 'mpesa',
        destination: json['destination']?.toString() ?? '',
        status: payoutDestinationStatusFromString(json['status']?.toString()),
        isDefault: json['is_default'] == true,
        verificationMethod: json['verification_method']?.toString(),
        verifiedAt: DateTime.tryParse(json['verified_at']?.toString() ?? ''),
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
        verification: json['verification'] is Map<String, dynamic>
            ? PayoutChallenge.fromJson(json['verification'] as Map<String, dynamic>)
            : null,
      );
}
