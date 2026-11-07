import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/verification_service.dart';
import 'package:help24/utils/error_mapper.dart';
import 'package:help24/utils/vetting_labels.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Provider vetting (migration 135) on the client: what a listing says about
/// its provider, what the verification screen believes the member may do, and
/// how the database's refusals read.
///
/// The database is the authority for every rule
/// (supabase/tests/trust-safety/vetting.test.mjs). These tests hold the client
/// to the same vocabulary.

Map<String, dynamic> _row({
  String type = 'offer',
  String category = 'Babysitting',
  String? vettingLabel,
  bool? idVerified,
  String? careStatus,
}) =>
    {
      'id': 'p1',
      'title': 'Evening sitter',
      'description': 'd',
      'category': category,
      'location': 'Nyali',
      'urgency': 'flexible',
      'price': 500,
      'type': type,
      'author_user_id': 'u1',
      'created_at': '2026-11-07T08:00:00Z',
      if (vettingLabel != null) 'vetting_label': vettingLabel,
      'users': {
        'name': 'Achieng',
        if (idVerified != null) 'id_verified': idVerified,
        if (careStatus != null) 'care_status': careStatus,
      },
    };

void main() {
  group('PostModel reads the vetting columns', () {
    test('label and author badges are parsed; unknown values are dropped', () {
      final p = PostModel.fromJson(_row(vettingLabel: 'certificate_pending', idVerified: true, careStatus: 'pending'));
      expect(p.vettingLabel, 'certificate_pending');
      expect(p.authorIdVerified, isTrue);
      expect(p.authorCareStatus, 'pending');

      final odd = PostModel.fromJson(_row(vettingLabel: 'something_else', careStatus: 'none'));
      expect(odd.vettingLabel, isNull);
      expect(odd.authorCareStatus, isNull);
      expect(odd.authorIdVerified, isFalse);
    });

    test('rows from before migration 135 (no columns) read as unverified, unlabelled', () {
      final p = PostModel.fromJson(_row());
      expect(p.vettingLabel, isNull);
      expect(p.authorIdVerified, isFalse);
      expect(p.authorCareStatus, isNull);
    });

    test('copyWith keeps the vetting fields', () {
      final p = PostModel.fromJson(_row(vettingLabel: 'not_verified', idVerified: true, careStatus: 'checked'));
      final c = p.copyWith(title: 'New title');
      expect(c.vettingLabel, 'not_verified');
      expect(c.authorIdVerified, isTrue);
      expect(c.authorCareStatus, 'checked');
    });
  });

  group('listingVettingLabel', () {
    test('the caution labels win over the badges', () {
      expect(listingVettingLabel(PostModel.fromJson(_row(vettingLabel: 'certificate_pending', idVerified: true, careStatus: 'pending'))),
          const VettingLabel('Certificate pending', VettingTone.caution));
      expect(listingVettingLabel(PostModel.fromJson(_row(vettingLabel: 'not_verified'))),
          const VettingLabel('Not yet verified', VettingTone.caution));
    });

    test('Care checked outranks ID verified', () {
      expect(listingVettingLabel(PostModel.fromJson(_row(idVerified: true, careStatus: 'checked'))),
          const VettingLabel('Care checked', VettingTone.positive));
      expect(listingVettingLabel(PostModel.fromJson(_row(category: 'Plumbing', idVerified: true))),
          const VettingLabel('ID verified', VettingTone.positive));
    });

    test('only offers carry it — requests and jobs are posted by the people hiring', () {
      expect(listingVettingLabel(PostModel.fromJson(_row(type: 'request', idVerified: true, careStatus: 'checked'))), isNull);
      expect(listingVettingLabel(PostModel.fromJson(_row(type: 'job', vettingLabel: 'not_verified'))), isNull);
      expect(listingVettingLabel(PostModel.fromJson(_row())), isNull);
    });

    test('a pending certificate is explained on the detail page', () {
      expect(listingVettingExplanation(PostModel.fromJson(_row(vettingLabel: 'certificate_pending'))),
          contains('cannot be hired for care work'));
      expect(listingVettingExplanation(PostModel.fromJson(_row(idVerified: true))), isNull);
    });

    test('"Not yet verified" is said once — no sentence repeating the label', () {
      expect(listingVettingExplanation(PostModel.fromJson(_row(vettingLabel: 'not_verified'))), isNull);
    });
  });

  group('VerificationStatus mirrors the database rules', () {
    final tiers = {'Babysitting': 'care', 'Caregiving': 'care', 'Tutoring': 'id', 'Driver': 'id'};

    VerificationStatus status({bool id = false, String care = 'none'}) =>
        VerificationStatus.fromJson({'id_verified': id, 'care_status': care, 'latest': {}, 'tiers': tiers});

    test('no check: anything outside the tiers, nothing inside', () {
      final s = status();
      expect(s.canOffer('Plumbing'), isTrue);
      expect(s.canApply('Plumbing'), isTrue);
      expect(s.canOffer('Tutoring'), isFalse);
      expect(s.canOffer('Babysitting'), isFalse);
    });

    test('ID check opens ID-tier work, not care work', () {
      final s = status(id: true);
      expect(s.canOffer('Tutoring'), isTrue);
      expect(s.canApply('Driver'), isTrue);
      expect(s.canOffer('Caregiving'), isFalse);
    });

    test('certificate pending: may OFFER care work, may not APPLY for it', () {
      final s = status(id: true, care: 'pending');
      expect(s.canOffer('Babysitting'), isTrue);
      expect(s.canApply('Babysitting'), isFalse);
    });

    test('Care check complete: everything', () {
      final s = status(id: true, care: 'checked');
      expect(s.canOffer('Babysitting'), isTrue);
      expect(s.canApply('Caregiving'), isTrue);
    });

    test('the latest submissions are read without file paths', () {
      final s = VerificationStatus.fromJson({
        'id_verified': false,
        'care_status': 'none',
        'latest': {
          'id': {'document_type': 'passport', 'status': 'rejected', 'rejection_reason': 'The photo is blurred.'},
        },
        'tiers': tiers,
      });
      expect(s.latestId?.document, VerificationDocument.passport);
      expect(s.latestId?.isRejected, isTrue);
      expect(s.latestId?.rejectionReason, 'The photo is blurred.');
      expect(s.latestCare, isNull);
    });

    test('each document asks for the number of files the database expects', () {
      expect(VerificationDocument.nationalId.steps, hasLength(3));
      expect(VerificationDocument.alienId.steps, hasLength(3));
      expect(VerificationDocument.passport.steps, hasLength(2));
      expect(VerificationDocument.certificate.steps, hasLength(1));
      expect(VerificationDocument.receipt.steps, hasLength(1));
      expect(VerificationDocument.forKind(VerificationKind.care),
          [VerificationDocument.certificate, VerificationDocument.receipt]);
    });
  });

  group('ErrorMapper: vetting refusals read as a next step', () {
    test('offering care work without a Care check', () {
      final f = ErrorMapper.toFailure(const PostgrestException(
        message: 'HELP24_VERIFICATION_REQUIRED: offering this work needs a Care check',
        code: '42501',
      ));
      expect(f.title, 'Care check needed');
      expect(f.message, contains('Verify your identity'));
      expect(f.category, ErrorCategory.authorization);
    });

    test('applying for ID-check work', () {
      final f = ErrorMapper.toFailure(const PostgrestException(
        message: 'HELP24_VERIFICATION_REQUIRED: applying for this work needs an ID check',
        code: '42501',
      ));
      expect(f.title, 'ID check needed');
      expect(f.message, contains('This work needs a verified ID'));
    });

    test('a listing hidden for verification', () {
      final f = ErrorMapper.toFailure(const PostgrestException(
        message: 'HELP24_VERIFICATION_REQUIRED: this listing reopens when your verification is approved',
        code: '42501',
      ));
      expect(f.title, 'Hidden until you are verified');
    });

    test('the backend refusing to hire an unverified provider', () {
      final f = ErrorMapper.toFailure(Exception(
          'This provider has not completed the Care check (ID and Certificate of Good Conduct) needed for care work, so they cannot be hired for it yet.'));
      expect(f.title, 'This provider is not verified yet');
      expect(f.category, ErrorCategory.conflict);
    });

    test('submission problems show the sentence written for people, without the marker', () {
      final f = ErrorMapper.toFailure(const PostgrestException(
        message: 'HELP24_VERIFICATION_INVALID: send your ID first — the Care check includes it',
        code: '22023',
      ));
      // The server's dash reads as two sentences: no dashes on screen.
      expect(f.message, 'Send your ID first. The Care check includes it.');
      expect(f.message, isNot(contains('HELP24')));
      final upload = ErrorMapper.toFailure(const PostgrestException(
        message: 'HELP24_VERIFICATION_INVALID: a photo did not finish uploading — try again',
        code: '22023',
      ));
      expect(upload.message, 'A photo did not finish uploading. Try again.');
      final pending = ErrorMapper.toFailure(const PostgrestException(
        message: 'HELP24_VERIFICATION_PENDING: we are still reviewing what you sent',
        code: '22023',
      ));
      expect(pending.title, 'Already in review');
    });
  });
}
