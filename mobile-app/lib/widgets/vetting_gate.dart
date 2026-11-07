import 'package:flutter/material.dart';

import '../screens/provider/verification_screen.dart';
import '../services/verification_service.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';

/// Asks for verification BEFORE a provider fills in work the database will
/// refuse (migration 135): offering, or applying for, work in a category that
/// needs an ID check or a Care check.
///
/// Fails OPEN on a read error, like ensureProviderReady: the database enforces
/// the rule anyway, and blocking someone because a status read timed out is
/// worse than letting the server answer.
Future<bool> ensureVettedFor(
  BuildContext context, {
  required String uid,
  required String categoryName,
  required bool applying,
  Future<VerificationStatus?>? known,
}) async {
  if (uid.isEmpty) return true;
  VerificationStatus? status = known == null ? null : await known;
  if (status == null) {
    try {
      status = await VerificationService.myStatus();
    } catch (e) {
      debugPrint('[VETTING_GATE] status read failed, failing open: $e');
      return true;
    }
  }
  if (!context.mounted) return false;

  final tier = status.tierFor(categoryName);
  if (tier == null) return true;
  if (applying ? status.canApply(categoryName) : status.canOffer(categoryName)) return true;

  final care = tier == 'care';
  final certificatePending = status.certificatePending;
  final work = categoryName.isEmpty ? 'This work' : categoryName;
  final String title;
  final String body;
  if (care && applying && status.certificatePending) {
    title = 'Certificate still pending';
    body = 'You can list care work now. Applying for care jobs needs the certificate.';
  } else if (care) {
    title = 'Care check needed';
    body = '$work needs your ID and a DCI Certificate of Good Conduct. '
        'An eCitizen receipt lets you start for 30 days.';
  } else {
    title = 'ID check needed';
    body = '$work needs a verified ID. It takes a few minutes and is reviewed within 24 hours.';
  }

  final go = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      final c = AppColors.of(sheet);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.verified, color: c.contentPrimary),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(child: Text(title, style: AppTypeScale.headingS.copyWith(color: c.contentPrimary))),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              Text(body, style: AppTypeScale.bodyM.copyWith(color: c.contentSecondary)),
              const SizedBox(height: AppSpace.lg),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(sheet, true),
                  child: Text(care && certificatePending ? 'Upload my certificate' : 'Verify now'),
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              SizedBox(
                width: double.infinity,
                child: TextButton(onPressed: () => Navigator.pop(sheet, false), child: const Text('Not now')),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (go == true && context.mounted) {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VerificationScreen(uid: uid, focus: care ? VerificationKind.care : VerificationKind.id),
      ),
    );
  }
  return false;
}
