import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/profile_completion.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../services/profession_registry.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_mapper.dart';
import '../utils/phone_utils.dart';
import '../widgets/profile_editors.dart';
import '../widgets/profile_widgets.dart';

/// The Professional Profile — the hub that replaced the flat Edit Profile form.
///
/// STRUCTURE (spec §1): identity header with a completion ring, then two
/// sections — Personal Information and Professional Information. Each row
/// opens a focused editor for ONE field. Nothing is a long form; nothing is
/// saved implicitly.
///
/// PHONE IS READ-ONLY HERE, BY DESIGN. The number lives in Account behind
/// device authentication (Payment Settings). Duplicating the editor here would
/// create a second write path for the most security-sensitive field on the
/// account, so this screen shows it and points back — one source of truth, one
/// flow.
class ProfessionalProfileScreen extends StatefulWidget {
  final String uid;
  final UserModel? initialProfile;
  final String emailFromAuth;

  /// Phone from the auth session, used only as a fallback when the users row
  /// has not synced yet. Never written from this screen.
  final String? phoneFromAuth;

  const ProfessionalProfileScreen({
    super.key,
    required this.uid,
    this.initialProfile,
    required this.emailFromAuth,
    this.phoneFromAuth,
  });

  @override
  State<ProfessionalProfileScreen> createState() => _ProfessionalProfileScreenState();
}

class _ProfessionalProfileScreenState extends State<ProfessionalProfileScreen> {
  UserModel? _profile;
  bool _loading = false;
  bool _uploadingPhoto = false;

  /// True once anything was saved — returned to the caller so the Account tab
  /// refreshes its hero without polling.
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = _profile == null);
    final fresh = await UserProfileService.getUser(widget.uid);
    if (!mounted) return;
    setState(() {
      if (fresh != null) _profile = fresh;
      _loading = false;
    });
  }

  /// Run an editor and refresh on a real save.
  Future<void> _afterEdit(Future<bool?> editor) async {
    final saved = await editor;
    if (saved == true) {
      _changed = true;
      await _refresh();
    }
  }

  Future<void> _changePhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;

      setState(() => _uploadingPhoto = true);
      await UserProfileService.uploadProfileImage(picked, widget.uid);
      if (!mounted) return;

      // Keep Firebase Auth's photo in step so surfaces reading the session
      // user (chat headers, cached cards) do not show the previous avatar.
      final fresh = await UserProfileService.getUser(widget.uid);
      if (!mounted) return;
      if (fresh != null && fresh.profileImage.isNotEmpty && context.mounted) {
        await context.read<AuthProvider>().updateProfile(photoUrl: fresh.profileImage);
      }
      if (!mounted) return;
      _changed = true;
      setState(() {
        if (fresh != null) _profile = fresh;
        _uploadingPhoto = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploadingPhoto = false);
      _toast(ErrorMapper.toMessage(e, context: ErrorContext.upload), isError: true);
    }
  }

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? AppTheme.errorRed : AppTheme.successGreen,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// The phone is managed in Account. Rather than opening a second editor, we
  /// say so and take the user back there — the sheet lives on the Account tab
  /// behind its biometric gate.
  void _explainPhoneIsManagedInAccount() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ProfileEditorSheet(
        title: 'Phone number',
        subtitle:
            'Your number is used for M-Pesa payments and payouts, so it is changed '
            'in Account with device authentication. It is shown here for reference only.',
        children: [
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: () {
                Navigator.pop(sheetContext);
                // Back to Account → Payment Settings, the one place it changes.
                Navigator.of(context).pop(_changed);
              },
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Change in Account'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final completion =
        ProfileCompletion.of(profile, fallbackPhone: widget.phoneFromAuth);

    final phone = (profile?.phone ?? '').trim().isNotEmpty
        ? profile!.phone!.trim()
        : (widget.phoneFromAuth ?? '').trim();
    final email = (profile?.email ?? '').trim().isNotEmpty
        ? profile!.email.trim()
        : widget.emailFromAuth;
    final storedProfession = profile?.profession ?? '';
    final professionLabel = ProfessionRegistry.instance.labelFor(storedProfession);
    final professionIsLegacy = professionLabel.isNotEmpty &&
        !ProfessionRegistry.instance.isConfirmed(storedProfession);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
        appBar: AppBar(
          title: const Text('Professional Profile'),
          centerTitle: true,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: () => Navigator.of(context).pop(_changed),
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _refresh,
                color: AppTheme.primaryAccent,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                  children: [
                    _Header(
                      profile: profile,
                      fallbackName: context.read<AuthProvider>().currentUserName,
                      completion: completion,
                      uploading: _uploadingPhoto,
                      onChangePhoto: _changePhoto,
                    ),
                    const SizedBox(height: 20),

                    _CompletionCard(
                      completion: completion,
                      onTapField: _openEditorForKey,
                    ),
                    const SizedBox(height: 24),

                    ProfileSectionCard(
                      title: ProfileSection.personal.title,
                      children: [
                        ProfileFieldRow(
                          icon: Icons.person_outline_rounded,
                          label: 'Full name',
                          value: profile?.name,
                          emptyHint: 'Add your name',
                          onTap: () => _openEditorForKey('name'),
                        ),
                        ProfileFieldRow(
                          icon: Icons.mail_outline_rounded,
                          label: 'Email',
                          value: email,
                          emptyHint: 'Not set',
                          note: 'From your sign-in',
                          // Read-only: identity comes from the auth provider.
                          onTap: null,
                        ),
                        ProfileFieldRow(
                          icon: Icons.phone_iphone_rounded,
                          label: 'Phone number',
                          // Masked here exactly as it is on the Account tile —
                          // the full value is only revealed behind the
                          // biometric gate.
                          value: phone.isEmpty ? null : maskPhone(phone),
                          emptyHint: 'Not set',
                          note: phone.isEmpty
                              ? 'Add it in Account to get paid'
                              : 'Managed in Account',
                          onTap: _explainPhoneIsManagedInAccount,
                        ),
                        ProfileFieldRow(
                          icon: Icons.verified_outlined,
                          label: 'Member since',
                          value: _memberSince(profile),
                          emptyHint: '—',
                          showDivider: false,
                          onTap: null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    ProfileSectionCard(
                      title: ProfileSection.professional.title,
                      caption: 'What clients see when deciding who to hire.',
                      children: [
                        ProfileFieldRow(
                          icon: Icons.work_outline_rounded,
                          label: 'Profession',
                          value: professionLabel.isEmpty ? null : professionLabel,
                          emptyHint: 'Choose your profession',
                          note: professionIsLegacy
                              ? 'Tap to confirm from the list'
                              : null,
                          needsAttention: professionIsLegacy,
                          onTap: () => _openEditorForKey('profession'),
                        ),
                        ProfileFieldRow(
                          icon: Icons.notes_rounded,
                          label: 'About you',
                          value: profile?.bio,
                          emptyHint: 'Add a short intro',
                          showDivider: false,
                          onTap: () => _openEditorForKey('bio'),
                        ),
                      ],
                    ),

                    if (completion.comingSoon.isNotEmpty) ...[
                      const SizedBox(height: 24),
                      _ComingSoonCard(specs: completion.comingSoon),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  static String? _memberSince(UserModel? profile) {
    final created = profile?.createdAt;
    if (created == null) return null;
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final local = created.toLocal();
    return '${months[local.month - 1]} ${local.year}';
  }

  /// Single dispatch point from field key → editor, so the checklist and the
  /// section rows can never drift out of sync.
  void _openEditorForKey(String key) {
    final profile = _profile;
    switch (key) {
      case 'photo':
        _changePhoto();
      case 'name':
        _afterEdit(showNameEditor(
          context,
          uid: widget.uid,
          currentName: profile?.name ?? '',
          nameChangedAt: profile?.nameChangedAt,
        ));
      case 'phone':
        _explainPhoneIsManagedInAccount();
      case 'profession':
        _afterEdit(showProfessionPicker(
          context,
          uid: widget.uid,
          currentProfession: profile?.profession,
        ));
      case 'bio':
        _afterEdit(showBioEditor(
          context,
          uid: widget.uid,
          currentBio: profile?.bio ?? '',
        ));
    }
  }
}

/// Identity header: avatar (tap to change), name, profession chip, ring.
class _Header extends StatelessWidget {
  final UserModel? profile;
  final String fallbackName;
  final ProfileCompletion completion;
  final bool uploading;
  final VoidCallback onChangePhoto;

  const _Header({
    required this.profile,
    required this.fallbackName,
    required this.completion,
    required this.uploading,
    required this.onChangePhoto,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final name = (profile?.name ?? '').trim().isNotEmpty
        ? profile!.name.trim()
        : fallbackName;

    return Row(
      children: [
        GestureDetector(
          onTap: uploading ? null : onChangePhoto,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ProfileAvatar(
                imageUrl: profile?.profileImage ?? '',
                name: name,
                size: 78,
                showGradient: true,
              ),
              if (uploading)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryAccent,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
                      width: 2,
                    ),
                  ),
                  child: const Icon(Icons.camera_alt_rounded,
                      color: Colors.white, size: 14),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? 'Your profile' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              if ((profile?.profession ?? '').trim().isNotEmpty)
                ProfessionChip(profession: profile!.profession)
              else
                Text('Add your profession',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(width: 12),
        CompletionRing(percent: completion.percent),
      ],
    );
  }
}

/// Completion summary. Collapsed by default (headline + next best action);
/// expands to the full checklist. Progressive disclosure, not a wall of boxes.
class _CompletionCard extends StatefulWidget {
  final ProfileCompletion completion;
  final void Function(String key) onTapField;

  const _CompletionCard({required this.completion, required this.onTapField});

  @override
  State<_CompletionCard> createState() => _CompletionCardState();
}

class _CompletionCardState extends State<_CompletionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final completion = widget.completion;
    final next = completion.nextStep;
    final active = completion.activeItems;
    final done = active.where((i) => i.complete).length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: completion.isComplete
              ? AppTheme.successGreen.withValues(alpha: 0.4)
              : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      completion.isComplete
                          ? 'Your profile is complete'
                          : '${completion.percent}% complete',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      completion.isComplete
                          ? 'Clients see everything they need to hire you.'
                          : next != null
                              ? 'Next: ${next.label.toLowerCase()} — ${next.hint.toLowerCase()}'
                              : '$done of ${active.length} steps done',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(_expanded ? 'Hide' : 'Details'),
              ),
            ],
          ),
          if (!completion.isComplete && next != null && !_expanded) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: () => widget.onTapField(next.key),
                child: Text('Add ${next.label.toLowerCase()}'),
              ),
            ),
          ],
          if (_expanded) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 4),
            for (final item in active)
              CompletionChecklistRow(
                state: item,
                onTap: item.complete ? null : () => widget.onTapField(item.spec.key),
              ),
          ],
        ],
      ),
    );
  }
}

/// Roadmap group. Declared fields that are not live yet — visible so the
/// profile reads as something that grows, but EXCLUDED from the percentage so
/// nobody is stuck below 100% waiting for a feature.
class _ComingSoonCard extends StatelessWidget {
  final List<ProfileFieldSpec> specs;

  const _ComingSoonCard({required this.specs});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color: (isDark ? AppTheme.darkCard : AppTheme.lightCard)
            .withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (isDark ? AppTheme.darkBorder : AppTheme.lightBorder)
              .withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Coming soon', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            'More ways to show your work. These do not affect your completion.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final spec in specs)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: (isDark ? AppTheme.darkBorder : AppTheme.lightBorder)
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    spec.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppTheme.darkTextTertiary
                          : AppTheme.lightTextTertiary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
