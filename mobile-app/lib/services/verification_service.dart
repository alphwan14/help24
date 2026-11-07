import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Provider vetting (migration 135): the ID check and the Care check.
///
/// The app talks to the database directly, the same way it posts:
///   1. each photo / PDF is uploaded to the PRIVATE `provider-verifications`
///      bucket under `<uid>/<random>.<ext>` (migration 136 lets a member write
///      only into their own folder, and read nothing back);
///   2. `submit_provider_verification(kind, document_type, files)` records the
///      submission — it checks the files are the caller's own and really
///      uploaded, and that nothing of that kind is already in review;
///   3. `my_verification_status()` reads back the caller's own status. It
///      never returns file paths or who reviewed.
///
/// The rules (who may offer or apply for which work) are enforced by the
/// database whatever this client does; this service only gets documents in.
class VerificationService {
  VerificationService._();

  static SupabaseClient get _client => Supabase.instance.client;
  static const String bucket = 'provider-verifications';

  /// eCitizen issues the certificate and the receipt as PDFs; ID photos are
  /// images. Matches migration 136's bucket limits.
  static const int maxBytes = 8 * 1024 * 1024;

  static Future<VerificationStatus> myStatus() async {
    final raw = await _client.rpc('my_verification_status');
    if (raw is Map) return VerificationStatus.fromJson(Map<String, dynamic>.from(raw));
    return VerificationStatus.empty;
  }

  /// Uploads one document and returns its storage path.
  static Future<String> upload({
    required String uid,
    required Uint8List bytes,
    required String extension,
  }) async {
    if (bytes.length > maxBytes) {
      throw const VerificationException('That file is larger than 8 MB. Take the photo again, or send a smaller PDF.');
    }
    final ext = _normaliseExtension(extension);
    final path = '$uid/${const Uuid().v4()}.$ext';
    await _client.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(upsert: false, contentType: contentTypeFor(ext)),
        );
    return path;
  }

  /// Records a submission. [files] are paths returned by [upload], in the
  /// order the document asks for (ID: front, back, selfie; passport: photo
  /// page, selfie).
  static Future<void> submit({
    required VerificationKind kind,
    required VerificationDocument document,
    required List<String> files,
  }) async {
    await _client.rpc('submit_provider_verification', params: {
      'p_kind': kind.wire,
      'p_document_type': document.wire,
      'p_files': files,
    });
  }

  static String _normaliseExtension(String raw) {
    final e = raw.toLowerCase().replaceAll('.', '');
    if (e == 'jpeg') return 'jpg';
    if (const ['jpg', 'png', 'webp', 'pdf'].contains(e)) return e;
    debugPrint('[VERIFY] unexpected extension "$raw", uploading as jpg');
    return 'jpg';
  }

  @visibleForTesting
  static String contentTypeFor(String ext) => switch (ext) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        'pdf' => 'application/pdf',
        _ => 'image/jpeg',
      };
}

class VerificationException implements Exception {
  final String message;
  const VerificationException(this.message);
  @override
  String toString() => message;
}

enum VerificationKind {
  id('id'),
  care('care');

  final String wire;
  const VerificationKind(this.wire);
}

/// The documents a member can send, and the photos each one needs.
enum VerificationDocument {
  nationalId('national_id', VerificationKind.id, 'National ID', ['Front of your ID', 'Back of your ID', 'A selfie holding your ID']),
  passport('passport', VerificationKind.id, 'Passport', ['The photo page', 'A selfie holding your passport']),
  alienId('alien_id', VerificationKind.id, 'Alien ID', ['Front of your Alien ID', 'Back of your Alien ID', 'A selfie holding your Alien ID']),
  certificate('certificate', VerificationKind.care, 'Certificate of Good Conduct', ['Your certificate (PDF from eCitizen, or a clear photo)']),
  receipt('receipt', VerificationKind.care, 'eCitizen application receipt', ['Your receipt (PDF from eCitizen, or a clear photo)']);

  final String wire;
  final VerificationKind kind;
  final String label;

  /// One entry per file, in upload order.
  final List<String> steps;

  const VerificationDocument(this.wire, this.kind, this.label, this.steps);

  static List<VerificationDocument> forKind(VerificationKind kind) =>
      values.where((d) => d.kind == kind).toList();

  static VerificationDocument? fromWire(String? wire) {
    for (final d in values) {
      if (d.wire == wire) return d;
    }
    return null;
  }
}

/// One submission as `my_verification_status()` reports it.
class VerificationSubmission {
  final VerificationDocument? document;
  final String status; // pending | approved | rejected
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final String? rejectionReason;
  final DateTime? expiresAt;

  const VerificationSubmission({
    required this.document,
    required this.status,
    this.submittedAt,
    this.reviewedAt,
    this.rejectionReason,
    this.expiresAt,
  });

  bool get isPending => status == 'pending';
  bool get isRejected => status == 'rejected';
  bool get isApproved => status == 'approved';

  factory VerificationSubmission.fromJson(Map<String, dynamic> json) => VerificationSubmission(
        document: VerificationDocument.fromWire(json['document_type']?.toString()),
        status: json['status']?.toString() ?? 'pending',
        submittedAt: DateTime.tryParse(json['submitted_at']?.toString() ?? ''),
        reviewedAt: DateTime.tryParse(json['reviewed_at']?.toString() ?? ''),
        rejectionReason: json['rejection_reason']?.toString(),
        expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
      );
}

/// What the signed-in member holds, and which categories need which check.
class VerificationStatus {
  final bool idVerified;

  /// 'checked' | 'pending' (receipt accepted, certificate due) | 'none'.
  final String careStatus;
  final DateTime? careExpiresAt;
  final VerificationSubmission? latestId;
  final VerificationSubmission? latestCare;

  /// Category name → 'id' | 'care'.
  final Map<String, String> tiers;

  const VerificationStatus({
    required this.idVerified,
    required this.careStatus,
    this.careExpiresAt,
    this.latestId,
    this.latestCare,
    this.tiers = const {},
  });

  static const empty = VerificationStatus(idVerified: false, careStatus: 'none');

  bool get careChecked => careStatus == 'checked';
  bool get certificatePending => careStatus == 'pending';

  /// The check a category needs, or null.
  String? tierFor(String categoryName) => tiers[categoryName];

  /// May this member OFFER work in [categoryName]? A pending certificate is
  /// enough to offer care work (the listing is labelled).
  bool canOffer(String categoryName) => switch (tierFor(categoryName)) {
        null => true,
        'id' => idVerified,
        'care' => careChecked || certificatePending,
        _ => false,
      };

  /// May this member APPLY for work in [categoryName]? Needs the full check.
  bool canApply(String categoryName) => switch (tierFor(categoryName)) {
        null => true,
        'id' => idVerified,
        'care' => careChecked,
        _ => false,
      };

  factory VerificationStatus.fromJson(Map<String, dynamic> json) {
    final latest = json['latest'] is Map ? Map<String, dynamic>.from(json['latest'] as Map) : const <String, dynamic>{};
    final tiers = <String, String>{};
    if (json['tiers'] is Map) {
      (json['tiers'] as Map).forEach((k, v) {
        if (v is String) tiers[k.toString()] = v;
      });
    }
    VerificationSubmission? sub(String key) =>
        latest[key] is Map ? VerificationSubmission.fromJson(Map<String, dynamic>.from(latest[key] as Map)) : null;
    return VerificationStatus(
      idVerified: json['id_verified'] == true,
      careStatus: json['care_status']?.toString() ?? 'none',
      careExpiresAt: DateTime.tryParse(json['care_expires_at']?.toString() ?? ''),
      latestId: sub('id'),
      latestCare: sub('care'),
      tiers: tiers,
    );
  }
}
