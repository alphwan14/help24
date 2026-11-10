import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_urls.dart';
import '../services/terms_acceptance.dart';
import '../theme/tokens.dart';
import '../utils/external_links.dart';
import '../utils/terms_copy.dart';

/// The terms a new install accepts before using Help24.
///
/// Shown by StartupGate over the app (which keeps building underneath, so the
/// feed is ready the moment this is accepted) whenever this install has not
/// accepted [TermsAcceptance.currentVersion]. Plain type and whitespace: a
/// summary people can actually read, with the full Terms and Privacy Policy a
/// tap away on help24.co.ke. Uses no icon, so it ships in a code patch.
class TermsAcceptanceScreen extends StatefulWidget {
  final VoidCallback onAccepted;

  const TermsAcceptanceScreen({super.key, required this.onAccepted});

  @override
  State<TermsAcceptanceScreen> createState() => _TermsAcceptanceScreenState();
}

class _TermsAcceptanceScreenState extends State<TermsAcceptanceScreen> {
  bool _saving = false;

  Future<void> _accept() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await TermsAcceptance.accept();
    } catch (e) {
      // A failed write still lets them in; it only means the screen returns
      // next launch, which is the safe direction.
      debugPrint('[TERMS] could not save acceptance: $e');
    }
    if (!mounted) return;
    widget.onAccepted();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final heading = TextStyle(color: c.contentPrimary, fontSize: 15, fontWeight: FontWeight.w600, height: 1.3);
    final body = TextStyle(color: c.contentSecondary, fontSize: 14, height: 1.5);

    return PopScope(
      // Back does not skip the terms; it leaves the app, as Close does.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) SystemNavigator.pop();
      },
      child: Scaffold(
        backgroundColor: c.page,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xxl, AppSpace.xl, AppSpace.xl),
                  children: [
                    Text(
                      TermsCopy.title,
                      style: TextStyle(
                        color: c.contentPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    Text(TermsCopy.lead, style: body.copyWith(fontSize: 15)),
                    const SizedBox(height: AppSpace.xxl),
                    for (final s in TermsCopy.sections) ...[
                      Text(s.heading, style: heading),
                      const SizedBox(height: AppSpace.xs + 2),
                      Text(s.body, style: body),
                      const SizedBox(height: AppSpace.xl),
                    ],
                    const SizedBox(height: AppSpace.sm),
                    _LinkText(
                      label: TermsCopy.readTerms,
                      color: c.accentText,
                      onTap: () => openHelp24Url(context, AppUrls.termsOfService),
                    ),
                    const SizedBox(height: AppSpace.md),
                    _LinkText(
                      label: TermsCopy.readPrivacy,
                      color: c.accentText,
                      onTap: () => openHelp24Url(context, AppUrls.privacyPolicy),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.lg),
                child: Column(
                  children: [
                    Text(
                      TermsCopy.agreementNote,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.contentTertiary, fontSize: 12.5, height: 1.4),
                    ),
                    const SizedBox(height: AppSpace.md),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton(
                        onPressed: _saving ? null : _accept,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.actionFill,
                          foregroundColor: c.contentOnAction,
                          shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
                        ),
                        child: Text(TermsCopy.accept,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    TextButton(
                      onPressed: _saving ? null : () => SystemNavigator.pop(),
                      style: TextButton.styleFrom(foregroundColor: c.contentSecondary),
                      child: const Text(TermsCopy.close),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkText extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _LinkText({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.smAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: Text(label, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}
