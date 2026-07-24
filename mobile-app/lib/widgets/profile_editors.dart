import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/profession.dart';
import '../models/profile_completion.dart';
import '../services/profession_registry.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_mapper.dart';
import '../utils/name_validator.dart';
import 'profile_widgets.dart';

// =============================================================================
// Focused profile editors.
//
// The old Edit Profile screen was one page holding every field behind a single
// Save. That shape gets worse with every field added, hides validation until
// submit, and risks clobbering a field the user never touched. Each editor
// here owns EXACTLY ONE field, validates as you type, and writes only that
// column — which is also what keeps the name-change trigger from firing on an
// unrelated save.
//
// Each returns `true` when something was saved, so the caller refreshes.
// =============================================================================

/// Edit the display name. Enforces shape client-side and surfaces the 30-day
/// cooldown BEFORE the user types rather than as a failed save.
Future<bool?> showNameEditor(
  BuildContext context, {
  required String uid,
  required String currentName,
  required DateTime? nameChangedAt,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NameEditorSheet(
      uid: uid,
      currentName: currentName,
      nameChangedAt: nameChangedAt,
    ),
  );
}

class _NameEditorSheet extends StatefulWidget {
  final String uid;
  final String currentName;
  final DateTime? nameChangedAt;

  const _NameEditorSheet({
    required this.uid,
    required this.currentName,
    required this.nameChangedAt,
  });

  @override
  State<_NameEditorSheet> createState() => _NameEditorSheetState();
}

class _NameEditorSheetState extends State<_NameEditorSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.currentName);
  String? _error;
  bool _saving = false;

  bool get _locked => !NameChangePolicy.canChange(widget.nameChangedAt);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final result = NameValidator.check(_controller.text);
    if (!result.ok) {
      setState(() => _error = result.error);
      return;
    }
    // A no-op save must not consume the 30-day allowance.
    if (result.normalized == widget.currentName.trim()) {
      Navigator.pop(context, false);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await UserProfileService.updateName(uid: widget.uid, name: result.normalized);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // Includes the database cooldown rejection, which ErrorMapper renders as
      // a rule rather than an error.
      if (mounted) {
        setState(() {
          _error = ErrorMapper.toMessage(e, context: ErrorContext.save);
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final restriction = NameChangePolicy.restrictionMessage(widget.nameChangedAt);
    return ProfileEditorSheet(
      title: 'Your name',
      subtitle: 'Use the name clients will see on your applications, chats and reviews.',
      children: [
        if (_error != null) InlineErrorBanner(message: _error!),
        TextField(
          controller: _controller,
          enabled: !_locked && !_saving,
          autofocus: !_locked,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          maxLength: NameValidator.maxLength,
          // Digits and symbols are rejected by the validator anyway; blocking
          // them at the keyboard means the user never types an invalid name in
          // the first place.
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r"[^\p{L}\p{M} .'’\-]", unicode: true)),
          ],
          decoration: const InputDecoration(
            labelText: 'Full name',
            hintText: 'e.g. Grace Wanjiku',
            prefixIcon: Icon(Icons.person_outline_rounded),
            counterText: '',
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _locked ? null : _save(),
        ),
        const SizedBox(height: 10),
        if (restriction != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _locked ? Icons.lock_clock_rounded : Icons.info_outline_rounded,
                size: 15,
                color: _locked ? AppTheme.warningOrange : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  restriction,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: _locked ? AppTheme.warningOrange : null,
                      ),
                ),
              ),
            ],
          ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: (_saving || _locked) ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Save name'),
          ),
        ),
      ],
    );
  }
}

/// Pick a profession from the controlled vocabulary. Searchable, because the
/// list grows server-side and a 40-item list must never become a scroll hunt.
Future<bool?> showProfessionPicker(
  BuildContext context, {
  required String uid,
  required String? currentProfession,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ProfessionPickerSheet(
      uid: uid,
      currentProfession: currentProfession,
    ),
  );
}

class _ProfessionPickerSheet extends StatefulWidget {
  final String uid;
  final String? currentProfession;

  const _ProfessionPickerSheet({required this.uid, this.currentProfession});

  @override
  State<_ProfessionPickerSheet> createState() => _ProfessionPickerSheetState();
}

class _ProfessionPickerSheetState extends State<_ProfessionPickerSheet> {
  final _search = TextEditingController();
  String _query = '';
  String? _saving;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Best-effort freshness; the list renders immediately from cache/bundled.
    ProfessionRegistry.instance.warmUp().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Profession> get _visible {
    final all = ProfessionRegistry.instance.all;
    if (_query.isEmpty) return all;
    final q = _query.toLowerCase();
    return all.where((p) => p.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _select(Profession profession) async {
    setState(() {
      _saving = profession.id;
      _error = null;
    });
    try {
      await UserProfileService.updateProfession(
        uid: widget.uid,
        professionId: profession.id,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = null;
          _error = ErrorMapper.toMessage(e, context: ErrorContext.save);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = ProfessionRegistry.instance.resolve(widget.currentProfession);
    final legacy = widget.currentProfession?.trim() ?? '';
    final hasLegacy = legacy.isNotEmpty && selected == null;
    final visible = _visible;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Your profession', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'This is how clients find and compare you. Pick the closest match.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            if (_error != null) InlineErrorBanner(message: _error!),
            if (hasLegacy) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warningOrange.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 18, color: AppTheme.warningOrange),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'You currently have "$legacy". Choose the matching '
                        'profession so clients can find you.',
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.warningOrange),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                hintText: 'Search professions',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No profession matches "$_query".\n'
                          'Pick "Other" if none fit.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final p = visible[i];
                        final isSelected = selected?.id == p.id;
                        final isSaving = _saving == p.id;
                        return ListTile(
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: Icon(p.icon, size: 20, color: AppTheme.primaryAccent),
                          ),
                          title: Text(
                            p.name,
                            style: TextStyle(
                              fontWeight:
                                  isSelected ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                          trailing: isSaving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : isSelected
                                  ? const Icon(Icons.check_circle_rounded,
                                      color: AppTheme.primaryAccent)
                                  : null,
                          onTap: _saving != null ? null : () => _select(p),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Edit the bio. Shows the "counts as complete" threshold honestly instead of
/// silently withholding credit for a two-word bio.
Future<bool?> showBioEditor(
  BuildContext context, {
  required String uid,
  required String currentBio,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _BioEditorSheet(uid: uid, currentBio: currentBio),
  );
}

class _BioEditorSheet extends StatefulWidget {
  final String uid;
  final String currentBio;

  const _BioEditorSheet({required this.uid, required this.currentBio});

  @override
  State<_BioEditorSheet> createState() => _BioEditorSheetState();
}

class _BioEditorSheetState extends State<_BioEditorSheet> {
  static const int _maxLength = 300;

  late final TextEditingController _controller =
      TextEditingController(text: widget.currentBio);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await UserProfileService.updateBio(uid: widget.uid, bio: _controller.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = ErrorMapper.toMessage(e, context: ErrorContext.save);
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final length = _controller.text.trim().length;
    final meetsBar = length >= ProfileFacts.minBioLength;
    return ProfileEditorSheet(
      title: 'About you',
      subtitle: 'A short introduction — what you do, and how long you have done it.',
      children: [
        if (_error != null) InlineErrorBanner(message: _error!),
        TextField(
          controller: _controller,
          enabled: !_saving,
          autofocus: true,
          maxLines: 5,
          maxLength: _maxLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText:
                'e.g. Licensed electrician with 8 years of experience across Nairobi. '
                'Wiring, fault-finding and emergency callouts.',
            hintMaxLines: 3,
            alignLabelWithHint: true,
            counterText: '',
          ),
          onChanged: (_) => setState(() => _error = null),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              meetsBar ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 15,
              color: meetsBar ? AppTheme.successGreen : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                meetsBar
                    ? 'Counts towards your profile completion.'
                    : 'Write at least ${ProfileFacts.minBioLength} characters to complete this step.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: meetsBar ? AppTheme.successGreen : null,
                    ),
              ),
            ),
            Text('$length/$_maxLength',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Save'),
          ),
        ),
      ],
    );
  }
}
