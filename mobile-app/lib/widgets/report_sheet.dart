import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/moderation.dart';
import '../providers/auth_provider.dart';
import '../services/report_service.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../utils/error_mapper.dart';
import 'auth_guard.dart';
import 'primitives.dart';

/// The one report flow, for every kind of target: an account, a listing, an
/// application to your listing, or a message you received.
///
/// WHAT THE REPORTER IS TOLD, AND WHAT THEY ARE NOT
/// ------------------------------------------------
/// They are told the report arrived. They are never told what happened next —
/// not whether the other person was warned, suspended or cleared — because an
/// outcome shown to one side of a dispute is information used against the
/// other. The reported person, likewise, is never told who reported them.
class ReportSheet extends StatefulWidget {
  const ReportSheet._({required this.target});

  final ReportTarget target;

  /// Open the sheet for [target]. Signed-out people are asked to sign in
  /// first: a report is attributed to its reporter, or it is not a report.
  static Future<void> show(BuildContext context, ReportTarget target) async {
    final uid = context.read<AuthProvider>().currentUserId ?? '';
    if (uid.isEmpty) {
      AuthGuard.requireAuth(
        context,
        action: 'send a report',
        onAuthenticated: () {
          if (context.mounted) unawaited(show(context, target));
        },
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ReportSheet._(target: target),
    );
  }

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

/// What a ⋮ overflow offers when more than one thing on screen could be
/// reported — a listing AND the person who posted it. One target skips
/// straight to the sheet.
class ReportMenu {
  ReportMenu._();

  static Future<void> show(BuildContext context, List<ReportTarget> targets) async {
    if (targets.isEmpty) return;
    if (targets.length == 1) return ReportSheet.show(context, targets.first);
    final picked = await showModalBottomSheet<ReportTarget>(
      context: context,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheet) {
        final c = AppColors.of(sheet);
        return Material(
          color: c.surface,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SheetHandle(),
                  AppRowGroup(children: [
                    for (final t in targets)
                      AppRow(
                        icon: AppIcons.report,
                        title: labelFor(t),
                        showChevron: false,
                        onTap: () => Navigator.of(sheet).pop(t),
                      ),
                  ]),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked != null && context.mounted) await ReportSheet.show(context, picked);
  }

  @visibleForTesting
  static String labelFor(ReportTarget t) => switch (t.type) {
        ReportTargetType.user => 'Report ${t.subjectName}',
        ReportTargetType.post => 'Report this listing',
        ReportTargetType.application => 'Report this application',
        ReportTargetType.message => 'Report this message',
      };
}

enum _Phase { form, sending, received, alreadyReported }

class _ReportSheetState extends State<ReportSheet> {
  ReportCategory? _category;
  final _details = TextEditingController();
  final List<ReportAttachment> _attachments = [];
  _Phase _phase = _Phase.form;
  String? _error;
  String? _reference;

  static const _emergencyCategories = {
    ReportCategory.threats,
    ReportCategory.unsafeBehavior,
    ReportCategory.illegalActivity,
  };

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  bool get _needsDetails => _category == ReportCategory.other;

  bool get _canSubmit =>
      _category != null &&
      _phase == _Phase.form &&
      (!_needsDetails || _details.text.trim().length >= 10);

  Future<void> _pickScreenshots() async {
    final remaining = ReportService.maxAttachments - _attachments.length;
    if (remaining <= 0) return;
    List<XFile> picked;
    try {
      final picker = ImagePicker();
      // pickMultiImage refuses a limit below 2.
      picked = remaining == 1
          ? [if (await picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85) case final x?) x]
          : await picker.pickMultiImage(maxWidth: 1600, imageQuality: 85, limit: remaining);
    } on PlatformException catch (e) {
      debugPrint('[REPORT] picker failed: $e');
      if (mounted) setState(() => _error = "We couldn't open your photos. Check Help24's photo permission.");
      return;
    }
    if (picked.isEmpty || !mounted) return;

    var skipped = 0;
    final added = <ReportAttachment>[];
    for (final file in picked.take(remaining)) {
      final mime = _mimeOf(file);
      final bytes = await file.readAsBytes();
      if (mime == null || bytes.length > ReportService.maxAttachmentBytes) {
        skipped++;
        continue;
      }
      added.add(ReportAttachment(bytes: bytes, mimeType: mime, name: file.name));
    }
    if (!mounted) return;
    setState(() {
      _attachments.addAll(added);
      _error = skipped > 0 ? 'Some images were skipped. Screenshots must be JPG, PNG or WEBP, under 10 MB.' : null;
    });
  }

  static String? _mimeOf(XFile file) {
    final declared = file.mimeType;
    if (declared != null && ReportService.allowedMimeTypes.contains(declared)) return declared;
    final name = file.name.toLowerCase();
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    return null;
  }

  Future<void> _submit() async {
    final category = _category;
    if (!_canSubmit || category == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _phase = _Phase.sending;
      _error = null;
    });
    try {
      final outcome = await ReportService.submit(
        target: widget.target,
        category: category,
        details: _details.text,
        attachments: List.of(_attachments),
      );
      if (!mounted) return;
      setState(() {
        _phase = outcome.kind == ReportOutcomeKind.received ? _Phase.received : _Phase.alreadyReported;
        _reference = outcome.reference;
      });
    } on ReportException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _error = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.form;
        _error = ErrorMapper.toMessage(e, context: ErrorContext.save);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.92;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Material(
          color: c.surface,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheetTop),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: AnimatedSize(
              duration: AppMotion.transition,
              curve: AppMotion.enter,
              alignment: Alignment.topCenter,
              child: switch (_phase) {
                _Phase.received || _Phase.alreadyReported => _done(c),
                _ => _form(c),
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(AppColors c) {
    final sending = _phase == _Phase.sending;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SheetHandle(),
          Text('Report', style: AppTypeScale.headingM.copyWith(color: c.contentPrimary)),
          const SizedBox(height: AppSpace.xs),
          Text(
            'Tell us what went wrong. Reports are reviewed by the Help24 team.',
            style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            widget.target.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTypeScale.meta.copyWith(color: c.contentTertiary),
          ),
          const SizedBox(height: AppSpace.lg),
          Text('What happened?', style: AppTypeScale.label.copyWith(color: c.contentPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpace.sm),
          for (final category in widget.target.categories)
            _CategoryRow(
              category: category,
              selected: _category == category,
              enabled: !sending,
              onTap: () => setState(() {
                _category = category;
                _error = null;
              }),
            ),
          if (_category != null && _emergencyCategories.contains(_category)) ...[
            const SizedBox(height: AppSpace.sm),
            _Notice(
              icon: AppIcons.warning,
              background: c.cautionSubtle,
              foreground: c.cautionText,
              text: 'If you are in immediate danger, call 999 or 112 first. Help24 cannot send help.',
            ),
          ],
          const SizedBox(height: AppSpace.lg),
          Text('Tell us more', style: AppTypeScale.label.copyWith(color: c.contentPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: _details,
            enabled: !sending,
            minLines: 3,
            maxLines: 6,
            maxLength: ReportService.maxDetails,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) => setState(() {}),
            style: AppTypeScale.bodyM.copyWith(color: c.contentPrimary),
            decoration: InputDecoration(
              hintText: _needsDetails
                  ? 'Describe what happened (required)'
                  : 'What happened, and when? Details help us act faster. (Optional)',
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          _Attachments(
            attachments: _attachments,
            enabled: !sending,
            onAdd: _pickScreenshots,
            onRemove: (i) => setState(() => _attachments.removeAt(i)),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.md),
            _Notice(icon: AppIcons.info, background: c.criticalSubtle, foreground: c.criticalText, text: _error!),
          ],
          const SizedBox(height: AppSpace.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: sending
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: c.contentOnAction),
                    )
                  : const Text('Submit Report'),
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            "Your report is confidential. We don't tell anyone who reported them.",
            textAlign: TextAlign.center,
            style: AppTypeScale.meta.copyWith(color: c.contentTertiary),
          ),
        ],
      ),
    );
  }

  Widget _done(AppColors c) {
    final received = _phase == _Phase.received;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetHandle(),
          const SizedBox(height: AppSpace.lg),
          Icon(received ? AppIcons.successFilled : AppIcons.info, size: 48, color: received ? c.positiveText : c.infoText),
          const SizedBox(height: AppSpace.md),
          Text(
            received ? 'Report submitted' : 'Already reported',
            style: AppTypeScale.headingM.copyWith(color: c.contentPrimary),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            received
                ? 'Thank you. Our team will review this report.'
                : "You've already reported this — our team is reviewing it.",
            textAlign: TextAlign.center,
            style: AppTypeScale.bodyM.copyWith(color: c.contentSecondary),
          ),
          if (received && (_reference?.isNotEmpty ?? false)) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              'Reference $_reference',
              style: AppTypeScale.mono.copyWith(color: c.contentTertiary, fontSize: 12),
            ),
          ],
          const SizedBox(height: AppSpace.xl),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({required this.category, required this.selected, required this.enabled, required this.onTap});

  final ReportCategory category;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? c.surfaceSunken : c.surface,
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
            side: BorderSide(color: selected ? c.contentPrimary : c.borderHairline, width: selected ? 1.5 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
                child: Row(
                  children: [
                    Icon(selected ? AppIcons.currentStep : AppIcons.unselected,
                        size: 20, color: selected ? c.contentPrimary : c.contentTertiary),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Text(
                        category.label,
                        style: AppTypeScale.bodyM.copyWith(
                          color: c.contentPrimary,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Attachments extends StatelessWidget {
  const _Attachments({required this.attachments, required this.enabled, required this.onAdd, required this.onRemove});

  final List<ReportAttachment> attachments;
  final bool enabled;
  final VoidCallback onAdd;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final canAdd = attachments.length < ReportService.maxAttachments;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (attachments.isNotEmpty) ...[
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (var i = 0; i < attachments.length; i++)
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: AppRadius.smAll,
                      child: Image.memory(attachments[i].bytes, width: 72, height: 72, fit: BoxFit.cover, gaplessPlayback: true),
                    ),
                    Positioned(
                      top: -6,
                      right: -6,
                      child: Semantics(
                        label: 'Remove screenshot',
                        button: true,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: enabled ? () => onRemove(i) : null,
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: c.contentPrimary,
                              shape: BoxShape.circle,
                              border: Border.all(color: c.surface, width: 2),
                            ),
                            child: Icon(AppIcons.close, size: 14, color: c.contentOnAction),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
        ],
        if (canAdd)
          TextButton.icon(
            onPressed: enabled ? onAdd : null,
            icon: const Icon(AppIcons.gallery, size: 18),
            label: Text(attachments.isEmpty
                ? 'Add screenshots (optional)'
                : 'Add another (${ReportService.maxAttachments - attachments.length} left)'),
          ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.background, required this.foreground, required this.text});

  final IconData icon;
  final Color background;
  final Color foreground;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(color: background, borderRadius: AppRadius.mdAll),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: AppSpace.sm),
          Expanded(child: Text(text, style: AppTypeScale.bodyS.copyWith(color: foreground))),
        ],
      ),
    );
  }
}
