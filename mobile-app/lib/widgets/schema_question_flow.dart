import 'dart:async';

import 'package:flutter/material.dart';

import '../models/category_schema.dart';
import '../theme/app_theme.dart';

/// Smart Posting (SP-2): the guided-conversation renderer.
///
/// Renders ANY [QuestionSchema] one question at a time — progressive
/// disclosure, big one-handed touch targets, auto-advance on choice taps.
/// There is deliberately no category-specific code here: the experience is
/// generated entirely from the schema, so new categories are DB rows.
///
/// Kept light for low-end phones: one 180ms fade/slide between questions,
/// no images, no shaders, plain widgets.
class SchemaQuestionFlow extends StatefulWidget {
  final QuestionSchema schema;
  final String postType; // request | offer | job
  final bool emergency; // urgency == urgent → schema hides skip_in_emergency steps
  final Map<String, dynamic> initialAnswers;
  final ValueChanged<Map<String, dynamic>> onAnswersChanged;
  final VoidCallback onFinished;

  const SchemaQuestionFlow({
    super.key,
    required this.schema,
    required this.postType,
    required this.emergency,
    this.initialAnswers = const {},
    required this.onAnswersChanged,
    required this.onFinished,
  });

  @override
  State<SchemaQuestionFlow> createState() => _SchemaQuestionFlowState();
}

class _SchemaQuestionFlowState extends State<SchemaQuestionFlow> {
  late final Map<String, dynamic> _answers = Map.of(widget.initialAnswers);
  final _textController = TextEditingController();
  int _index = 0;
  int _advanceToken = 0; // invalidates a pending auto-advance if state moves on

  List<QuestionStep> get _visible => widget.schema.visibleSteps(
        answers: _answers,
        postType: widget.postType,
        emergency: widget.emergency,
      );

  QuestionStep? get _current {
    final v = _visible;
    if (v.isEmpty) return null;
    return v[_index.clamp(0, v.length - 1)];
  }

  @override
  void initState() {
    super.initState();
    _syncTextController();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _syncTextController() {
    final step = _current;
    if (step != null && (step.type == 'text' || step.type == 'number')) {
      _textController.text = _answers[step.key]?.toString() ?? '';
    }
  }

  void _publish() {
    widget.onAnswersChanged(widget.schema.prunedAnswers(
      answers: _answers,
      postType: widget.postType,
      emergency: widget.emergency,
    ));
  }

  void _setAnswer(String key, dynamic value, {bool autoAdvance = false}) {
    setState(() => _answers[key] = value);
    _publish();
    if (autoAdvance) {
      // Brief pause so the selection highlight registers before moving on.
      final token = ++_advanceToken;
      Future.delayed(const Duration(milliseconds: 220), () {
        if (mounted && token == _advanceToken) _advance();
      });
    }
  }

  void _advance() {
    _advanceToken++;
    final v = _visible;
    if (_index >= v.length - 1) {
      widget.onFinished();
      return;
    }
    setState(() => _index++);
    _syncTextController();
  }

  void _goBack() {
    _advanceToken++;
    if (_index == 0) return;
    setState(() => _index--);
    _syncTextController();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final step = _current;
    if (step == null) {
      // Nothing to ask (all filtered out) — finish silently on next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onFinished();
      });
      return const SizedBox.shrink();
    }
    final visible = _visible;
    final position = _index.clamp(0, visible.length - 1);
    final subColor = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.emergency) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.errorRed.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bolt, size: 16, color: AppTheme.errorRed),
                const SizedBox(width: 6),
                Text(
                  'Quick post — only the essentials',
                  style: TextStyle(color: AppTheme.errorRed, fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            if (_index > 0)
              GestureDetector(
                onTap: _goBack,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(Icons.arrow_back_ios_new, size: 16, color: subColor),
                ),
              ),
            Text(
              'Question ${position + 1} of ${visible.length}',
              style: TextStyle(fontSize: 13, color: subColor),
            ),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0.06, 0), end: Offset.zero)
                  .animate(animation),
              child: child,
            ),
          ),
          child: Column(
            key: ValueKey(step.key),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(step.question, style: Theme.of(context).textTheme.headlineSmall),
              if (step.hint != null) ...[
                const SizedBox(height: 6),
                Text(step.hint!, style: TextStyle(fontSize: 13, color: subColor)),
              ],
              const SizedBox(height: 20),
              _buildInput(step, isDark),
              const SizedBox(height: 24),
              _buildFooter(step, isDark),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInput(QuestionStep step, bool isDark) {
    switch (step.type) {
      case 'select':
        return Column(
          children: [
            for (final o in step.options) ...[
              ChoiceTile(
                label: o.label,
                selected: _answers[step.key] == o.value,
                isDark: isDark,
                onTap: () => _setAnswer(step.key, o.value, autoAdvance: true),
              ),
              const SizedBox(height: 10),
            ],
          ],
        );
      case 'multiselect':
        final selected = (_answers[step.key] as List?)?.cast<String>() ?? const <String>[];
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final o in step.options)
              _ChoiceChip(
                label: o.label,
                selected: selected.contains(o.value),
                isDark: isDark,
                onTap: () {
                  final next = List<String>.of(selected);
                  next.contains(o.value) ? next.remove(o.value) : next.add(o.value);
                  _setAnswer(step.key, next);
                },
              ),
          ],
        );
      case 'boolean':
        return Row(
          children: [
            Expanded(
              child: ChoiceTile(
                label: 'Yes',
                selected: _answers[step.key] == true,
                isDark: isDark,
                onTap: () => _setAnswer(step.key, true, autoAdvance: true),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ChoiceTile(
                label: 'No',
                selected: _answers[step.key] == false,
                isDark: isDark,
                onTap: () => _setAnswer(step.key, false, autoAdvance: true),
              ),
            ),
          ],
        );
      case 'number':
      case 'text':
        return TextField(
          controller: _textController,
          keyboardType: step.type == 'number' ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(hintText: step.hint ?? 'Type here…'),
          onChanged: (v) {
            final value = step.type == 'number' ? num.tryParse(v.trim()) : v.trim();
            _setAnswer(step.key, value);
          },
          onSubmitted: (_) => _advance(),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildFooter(QuestionStep step, bool isDark) {
    final answered = !_isEmpty(_answers[step.key]);
    final isLast = _index >= _visible.length - 1;
    final needsContinue =
        step.type == 'multiselect' || step.type == 'text' || step.type == 'number';
    return Row(
      children: [
        if (!step.required)
          TextButton(
            onPressed: () {
              _answers.remove(step.key);
              _publish();
              _advance();
            },
            child: Text(
              'Skip',
              style: TextStyle(
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ),
        const Spacer(),
        if (needsContinue || answered)
          SizedBox(
            height: 46,
            child: ElevatedButton(
              onPressed: (step.required && !answered) ? null : _advance,
              child: Text(isLast ? 'Done' : 'Continue'),
            ),
          ),
      ],
    );
  }

  static bool _isEmpty(dynamic v) {
    if (v == null) return true;
    if (v is String) return v.trim().isEmpty;
    if (v is List) return v.isEmpty;
    return false;
  }
}

/// Full-width tappable option row — the primary one-handed input of the
/// guided flows (schema questions, When?, Budget). Shared across the wizard.
class ChoiceTile extends StatelessWidget {
  final String label;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final bool isDark;
  final VoidCallback onTap;

  const ChoiceTile({
    super.key,
    required this.label,
    this.subtitle,
    this.icon,
    required this.selected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryAccent.withValues(alpha: 0.15)
              : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppTheme.primaryAccent
                : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 22,
                color: selected
                    ? AppTheme.primaryAccent
                    : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? AppTheme.primaryAccent
                          : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, size: 20, color: AppTheme.primaryAccent),
          ],
        ),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isDark;
  final VoidCallback onTap;

  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryAccent.withValues(alpha: 0.15)
              : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected
                ? AppTheme.primaryAccent
                : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? AppTheme.primaryAccent
                : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
          ),
        ),
      ),
    );
  }
}
