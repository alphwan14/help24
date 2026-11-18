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
/// accepted [TermsAcceptance.currentVersion].
///
/// Read, then agree: the summary is a numbered card with a thin line under the
/// header that fills as the reader scrolls. The "read and understood" tick
/// unlocks only once they reach the end, and I agree only once it is ticked.
/// The full Terms and Privacy Policy stay a tap away on help24.co.ke. Uses no
/// icon font glyph, so it ships in a code patch.
class TermsAcceptanceScreen extends StatefulWidget {
  final VoidCallback onAccepted;

  const TermsAcceptanceScreen({super.key, required this.onAccepted});

  @override
  State<TermsAcceptanceScreen> createState() => _TermsAcceptanceScreenState();
}

class _TermsAcceptanceScreenState extends State<TermsAcceptanceScreen> {
  final _scroll = ScrollController();
  final _progress = ValueNotifier<double>(0);
  bool _reachedEnd = false;
  bool _understood = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // On a tall screen the whole summary may already fit: nothing to scroll.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final max = p.maxScrollExtent;
    _progress.value = max <= 0 ? 1 : (p.pixels / max).clamp(0.0, 1.0);
    if (!_reachedEnd && (max <= 0 || p.pixels >= max - 24)) {
      setState(() => _reachedEnd = true);
    }
  }

  Future<void> _accept() async {
    if (_saving || !_understood) return;
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
    final body = TextStyle(color: c.contentSecondary, fontSize: 14, height: 1.55);
    const sections = TermsCopy.sections;

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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header: stays put while the terms scroll under it ──────────
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xl, AppSpace.xl, AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
                    const SizedBox(height: AppSpace.sm),
                    Text(TermsCopy.lead, style: body.copyWith(fontSize: 15)),
                  ],
                ),
              ),
              // How far through the terms the reader is.
              ValueListenableBuilder<double>(
                valueListenable: _progress,
                builder: (_, v, __) => Stack(
                  children: [
                    Container(height: 2, color: c.borderHairline),
                    FractionallySizedBox(
                      alignment: AlignmentDirectional.centerStart,
                      widthFactor: v,
                      child: Container(height: 2, color: c.accentFill),
                    ),
                  ],
                ),
              ),

              // ── The terms ──────────────────────────────────────────────────
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, AppSpace.xl),
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: AppRadius.lgAll,
                        border: Border.all(color: c.borderHairline),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < sections.length; i++)
                            _Section(
                              number: i + 1,
                              heading: sections[i].heading,
                              body: sections[i].body,
                              headingStyle: heading,
                              bodyStyle: body,
                              divider: i < sections.length - 1,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _LinkText(
                            label: TermsCopy.readTerms,
                            color: c.accentText,
                            onTap: () => openHelp24Url(context, AppUrls.termsOfService),
                          ),
                          const SizedBox(height: AppSpace.xs),
                          _LinkText(
                            label: TermsCopy.readPrivacy,
                            color: c.accentText,
                            onTap: () => openHelp24Url(context, AppUrls.privacyPolicy),
                          ),
                          const SizedBox(height: AppSpace.md),
                          Text(
                            TermsCopy.agreementNote,
                            style: TextStyle(color: c.contentTertiary, fontSize: 12.5, height: 1.4),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Agree: always on screen, unlocked by reading ───────────────
              DecoratedBox(
                decoration: BoxDecoration(
                  color: c.page,
                  border: Border(top: BorderSide(color: c.borderHairline)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.md),
                  child: Column(
                    children: [
                      _Understood(
                        enabled: _reachedEnd && !_saving,
                        value: _understood,
                        hint: _reachedEnd ? null : TermsCopy.scrollHint,
                        onChanged: (v) => setState(() => _understood = v),
                      ),
                      const SizedBox(height: AppSpace.md),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed: (_understood && !_saving) ? _accept : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: c.actionFill,
                            foregroundColor: c.contentOnAction,
                            disabledBackgroundColor: c.surfaceSunken,
                            disabledForegroundColor: c.contentTertiary,
                            shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
                          ),
                          child: Text(TermsCopy.accept,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      TextButton(
                        onPressed: _saving ? null : () => SystemNavigator.pop(),
                        style: TextButton.styleFrom(foregroundColor: c.contentSecondary),
                        child: const Text(TermsCopy.close),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One numbered term inside the card.
class _Section extends StatelessWidget {
  final int number;
  final String heading;
  final String body;
  final TextStyle headingStyle;
  final TextStyle bodyStyle;
  final bool divider;

  const _Section({
    required this.number,
    required this.heading,
    required this.body,
    required this.headingStyle,
    required this.bodyStyle,
    required this.divider,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, AppSpace.lg),
      decoration: divider ? BoxDecoration(border: Border(bottom: BorderSide(color: c.borderHairline))) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.accentSubtle, shape: BoxShape.circle),
            child: Text(
              '$number',
              style: TextStyle(color: c.accentText, fontSize: 12, fontWeight: FontWeight.w600, height: 1),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(heading, style: headingStyle),
                ),
                const SizedBox(height: AppSpace.xs + 2),
                Text(body, style: bodyStyle),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "I have read and understood these terms". Dimmed, with a hint, until the
/// reader has scrolled to the end.
class _Understood extends StatelessWidget {
  final bool enabled;
  final bool value;
  final String? hint;
  final ValueChanged<bool> onChanged;

  const _Understood({required this.enabled, required this.value, required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1 : 0.5,
      child: Semantics(
        hint: hint,
        child: InkWell(
          onTap: enabled ? () => onChanged(!value) : null,
          borderRadius: AppRadius.smAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: value,
                    onChanged: enabled ? (v) => onChanged(v ?? false) : null,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    activeColor: c.actionFill,
                    checkColor: c.contentOnAction,
                    side: BorderSide(color: c.borderStrong, width: 1.5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        TermsCopy.confirm,
                        style: TextStyle(color: c.contentPrimary, fontSize: 14, fontWeight: FontWeight.w500, height: 1.3),
                      ),
                      if (hint != null) ...[
                        const SizedBox(height: 2),
                        Text(hint!, style: TextStyle(color: c.contentTertiary, fontSize: 12.5, height: 1.3)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
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
