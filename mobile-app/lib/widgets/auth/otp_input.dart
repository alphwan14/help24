import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// Six-box verification code entry.
///
/// WHY NOT SIX TEXT FIELDS
/// -----------------------
/// The obvious implementation — six `TextField`s wired together — is the one
/// that always ships broken: backspace on an empty box does nothing, pasting a
/// code fills only the first box, Android's SMS autofill targets one field and
/// drops five digits, and screen readers announce "edit box" six times.
///
/// So this widget is ONE hidden `EditableText` holding the whole code, with six
/// boxes painted from its value. Every hard case then falls out for free:
///   * paste → the whole code lands, because it is one field;
///   * SMS autofill (`AutofillHints.oneTimeCode`) → same, one target;
///   * backspace → ordinary text editing, no cross-field choreography;
///   * accessibility → one labelled field, announced once.
///
/// The boxes are pure presentation. That is the trick, and it is why this
/// behaves the way the OTP entry in a banking app behaves.
class OtpInput extends StatefulWidget {
  final int length;

  /// Fired on every change with the digits entered so far.
  final ValueChanged<String>? onChanged;

  /// Fired once the final digit lands — the caller submits immediately
  /// rather than making the user reach for a button they no longer need.
  final ValueChanged<String> onCompleted;

  /// True while verification is in flight: the boxes lock and dim.
  final bool enabled;

  /// Paints the boxes red and runs a short shake. Set after a rejected code.
  final bool hasError;

  final bool autofocus;

  const OtpInput({
    super.key,
    required this.onCompleted,
    this.onChanged,
    this.length = 6,
    this.enabled = true,
    this.hasError = false,
    this.autofocus = true,
  });

  @override
  State<OtpInput> createState() => OtpInputState();
}

class OtpInputState extends State<OtpInput> with SingleTickerProviderStateMixin {
  late final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode = FocusNode();
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  String get _code => _controller.text;

  @override
  void didUpdateWidget(covariant OtpInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A newly-reported error shakes once and asks for a correction.
    if (widget.hasError && !oldWidget.hasError) {
      _shake.forward(from: 0);
      HapticFeedback.mediumImpact();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _shake.dispose();
    super.dispose();
  }

  /// Clear the boxes and return focus — used after a rejected code so the user
  /// can simply start typing again.
  void clear() {
    _controller.clear();
    setState(() {});
    widget.onChanged?.call('');
    _focusNode.requestFocus();
  }

  void _handleChanged(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    final clamped = digits.length > widget.length
        ? digits.substring(0, widget.length)
        : digits;

    if (clamped != value) {
      _controller.value = TextEditingValue(
        text: clamped,
        selection: TextSelection.collapsed(offset: clamped.length),
      );
    }
    setState(() {});
    widget.onChanged?.call(clamped);

    if (clamped.length == widget.length) {
      // Auto-submit: the code is complete and there is nothing left to decide.
      HapticFeedback.selectionClick();
      FocusScope.of(context).unfocus();
      widget.onCompleted(clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        // Damped sine: three decreasing swings, settling at zero.
        final t = _shake.value;
        final dx = t == 0 ? 0.0 : (1 - t) * 9 * math.sin(t * 3 * 2 * math.pi);
        return Transform.translate(offset: Offset(dx, 0), child: child);
      },
      child: Stack(
        children: [
          // The real input, held off-screen but focusable and autofill-visible.
          // Opacity 0 alone would keep it hittable; it is sized to the boxes so
          // taps anywhere on the row land here.
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                autofocus: widget.autofocus,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                // Android SMS Retriever / iOS "From Messages" autofill.
                autofillHints: const [AutofillHints.oneTimeCode],
                maxLength: widget.length,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(widget.length),
                ],
                onChanged: _handleChanged,
                showCursor: false,
                decoration: const InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          // The visible boxes.
          Semantics(
            label: 'Verification code, ${widget.length} digits',
            textField: true,
            value: _code,
            child: GestureDetector(
              onTap: widget.enabled ? () => _focusNode.requestFocus() : null,
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(widget.length, _buildBox),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBox(int index) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final filled = index < _code.length;
    final isNext = index == _code.length && _focusNode.hasFocus;

    final borderColor = widget.hasError
        ? AppTheme.errorRed
        : isNext
            ? AppTheme.primaryAccent
            : filled
                ? (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary)
                : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder);

    return Expanded(
      child: Padding(
        padding: EdgeInsets.only(right: index == widget.length - 1 ? 0 : 8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          height: 60,
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor,
              width: (isNext || widget.hasError) ? 1.8 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: widget.enabled ? 1 : 0.5,
            child: filled
                ? Text(
                    _code[index],
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: widget.hasError
                          ? AppTheme.errorRed
                          : (isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  )
                : isNext
                    // A caret in the next box, so the eye knows where it is.
                    ? Container(
                        width: 2,
                        height: 24,
                        decoration: BoxDecoration(
                          color: AppTheme.primaryAccent,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      )
                    : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

