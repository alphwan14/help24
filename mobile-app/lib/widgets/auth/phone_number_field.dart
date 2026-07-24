import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../utils/kenyan_phone.dart';

/// The phone entry control, built to the standard people already expect from
/// their banking and mobile-money apps.
///
/// DESIGN DECISIONS
/// ----------------
/// 1. **The country code is furniture, not content.** `+254` sits in its own
///    non-editable gutter, visually divided from the input by a hairline. A
///    user cannot type into it, delete it, or duplicate it — which is what
///    made the previous `prefixText` version produce `+2540712345678`.
/// 2. **The field cannot hold an illegal value.** A formatter reduces every
///    keystroke and paste to at most nine national digits and groups them
///    `712 345 678`. Letters are impossible; a tenth digit is impossible; a
///    pasted `+254 712 345 678` collapses to the same nine digits.
/// 3. **Errors arrive when they are useful.** A wrong leading digit is called
///    out immediately, because every further keystroke is wasted. A short
///    number is not — nobody wants "too short" while they are still typing.
/// 4. **Completion is visible.** The border turns green and a tick appears the
///    instant the number becomes dialable, so the user knows they are done
///    without reading anything.
class PhoneNumberField extends StatefulWidget {
  /// Called on every change with the national digits (no spaces, no +254).
  final ValueChanged<String> onChanged;

  /// Called when the user submits a COMPLETE number from the keyboard.
  final ValueChanged<String>? onSubmitted;

  /// Server- or flow-level error to display beneath the field (e.g. "Too many
  /// attempts"). Field-level validation is handled internally.
  final String? externalError;

  final bool enabled;
  final bool autofocus;
  final TextEditingController controller;

  const PhoneNumberField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.onSubmitted,
    this.externalError,
    this.enabled = true,
    this.autofocus = true,
  });

  @override
  State<PhoneNumberField> createState() => _PhoneNumberFieldState();
}

class _PhoneNumberFieldState extends State<PhoneNumberField> {
  final FocusNode _focusNode = FocusNode();
  String _national = '';
  bool _focused = false;

  /// Set once the user has tried to submit, so length complaints stay hidden
  /// during first entry but persist afterwards.
  bool _submitAttempted = false;

  @override
  void initState() {
    super.initState();
    _national = KenyanPhone.nationalDigitsFrom(widget.controller.text);
    _focusNode.addListener(() {
      if (mounted) setState(() => _focused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  /// Called by the parent when submission was attempted with an incomplete
  /// number, so the field can start showing length errors.
  void markSubmitted() => setState(() => _submitAttempted = true);

  bool get _isComplete => KenyanPhone.isValidNational(_national);

  String? get _fieldError {
    if (widget.externalError != null) return widget.externalError;
    final live = KenyanPhone.liveError(_national);
    if (live != null) return live;
    if (_submitAttempted) return KenyanPhone.submitError(_national);
    return null;
  }

  void _handleChanged(String text) {
    final national = KenyanPhone.nationalDigitsFrom(text);
    setState(() {
      _national = national;
      // A correction should clear a stale complaint immediately.
      if (national.length < KenyanPhone.nationalLength) return;
      _submitAttempted = _submitAttempted && !_isComplete;
    });
    widget.onChanged(national);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final error = _fieldError;
    final hasError = error != null;

    final borderColor = hasError
        ? AppTheme.errorRed
        : _isComplete
            ? AppTheme.successGreen
            : _focused
                ? AppTheme.primaryAccent
                : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder);

    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: 'Phone number, Kenya, plus 254',
          textField: true,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: borderColor,
                width: (_focused || hasError || _isComplete) ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                // ── Country gutter: structural, not editable ──────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        KenyanPhone.flagEmoji,
                        style: TextStyle(fontSize: 20),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        KenyanPhone.dialCode,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: textSecondary,
                          // Tabular figures keep the gutter from shifting.
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  height: 28,
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
                // ── The only editable region: 9 national digits ────────────
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    focusNode: _focusNode,
                    enabled: widget.enabled,
                    autofocus: widget.autofocus,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: false,
                      decimal: false,
                    ),
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.telephoneNumberNational],
                    // Letters and symbols never reach the field, so there is
                    // no "no letters allowed" error to write in the first place.
                    inputFormatters: const [KenyanPhoneInputFormatter()],
                    onChanged: _handleChanged,
                    onSubmitted: (_) {
                      markSubmitted();
                      if (_isComplete) widget.onSubmitted?.call(_national);
                    },
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    decoration: InputDecoration(
                      hintText: '712 345 678',
                      hintStyle: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.8,
                        color: textTertiary,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 18,
                      ),
                      // The completion tick — instant, wordless confirmation.
                      suffixIcon: _isComplete
                          ? const Padding(
                              padding: EdgeInsets.only(right: 14),
                              child: Icon(
                                Icons.check_circle_rounded,
                                color: AppTheme.successGreen,
                                size: 22,
                              ),
                            )
                          : null,
                      suffixIconConstraints:
                          const BoxConstraints(minWidth: 0, minHeight: 0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Helper ⇄ error occupy the same row, so nothing below reflows when
        // the message changes.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: hasError
              ? Row(
                  key: const ValueKey('error'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        size: 15, color: AppTheme.errorRed),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        error,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.errorRed,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                )
              : Text(
                  key: const ValueKey('hint'),
                  'Enter your number without the leading 0.',
                  style: TextStyle(fontSize: 13, color: textTertiary, height: 1.35),
                ),
        ),
      ],
    );
  }
}
