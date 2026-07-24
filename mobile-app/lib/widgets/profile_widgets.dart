import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/profession.dart';
import '../models/profile_completion.dart';
import '../services/profession_registry.dart';
import '../theme/app_theme.dart';

// =============================================================================
// Shared profile presentation.
//
// Every surface that shows "who this person is professionally" — the account
// hero, the Professional Profile hub, applicant cards, the public provider
// profile — renders through these, so a profession chip or an avatar looks and
// behaves identically everywhere. The alternative (each screen re-implementing
// the chip) is exactly how the old applicant list and post-detail applicant
// list drifted apart.
// =============================================================================

/// Profession chip. Renders the CANONICAL label for a stored key and falls
/// back to legacy free text verbatim, so no existing user's profession
/// disappears — see ProfessionRegistry.labelFor.
///
/// Returns an empty box when there is nothing to show; callers never need a
/// null check.
class ProfessionChip extends StatelessWidget {
  /// Raw `users.profession` value (a key, or legacy free text).
  final String? profession;
  final double fontSize;
  final bool dense;

  const ProfessionChip({
    super.key,
    required this.profession,
    this.fontSize = 12,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final label = ProfessionRegistry.instance.labelFor(profession);
    if (label.isEmpty) return const SizedBox.shrink();
    final resolved = ProfessionRegistry.instance.resolve(profession);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: AppTheme.primaryAccent.withValues(alpha: isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            resolved?.icon ?? Icons.work_outline,
            size: fontSize + 2,
            color: AppTheme.primaryAccent,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.primaryAccent,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Avatar with an initials fallback. One implementation instead of the four
/// slightly different `CircleAvatar` blocks that existed across the app.
class ProfileAvatar extends StatelessWidget {
  final String imageUrl;
  final String name;
  final double size;

  /// Gradient ring treatment (the account hero). Off for list rows.
  final bool showGradient;

  const ProfileAvatar({
    super.key,
    required this.imageUrl,
    required this.name,
    this.size = 48,
    this.showGradient = false,
  });

  String get _initials {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return trimmed[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final decoration = showGradient
        ? BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppTheme.primaryAccent, AppTheme.secondaryAccent],
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primaryAccent.withValues(alpha: 0.28),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          )
        : BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.primaryAccent.withValues(alpha: 0.14),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          );

    return Container(
      width: size,
      height: size,
      decoration: decoration,
      clipBehavior: Clip.antiAlias,
      child: imageUrl.trim().isEmpty
          ? Center(
              child: Text(
                _initials,
                style: TextStyle(
                  color: showGradient ? Colors.white : AppTheme.primaryAccent,
                  fontSize: size * 0.36,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : CachedNetworkImage(
              imageUrl: imageUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, __) => Center(
                child: SizedBox(
                  width: size * 0.3,
                  height: size * 0.3,
                  child: const CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white70,
                  ),
                ),
              ),
              errorWidget: (_, __, ___) => Center(
                child: Text(
                  _initials,
                  style: TextStyle(
                    color: showGradient ? Colors.white : AppTheme.primaryAccent,
                    fontSize: size * 0.36,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
    );
  }
}

/// Circular completion meter. The number IS the headline — a user should read
/// their progress in one glance without expanding anything.
class CompletionRing extends StatelessWidget {
  final int percent;
  final double size;
  final double stroke;

  const CompletionRing({
    super.key,
    required this.percent,
    this.size = 56,
    this.stroke = 5,
  });

  Color get _color {
    if (percent >= 100) return AppTheme.successGreen;
    if (percent >= 60) return AppTheme.primaryAccent;
    return AppTheme.warningOrange;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: math.min(percent, 100) / 100),
              duration: const Duration(milliseconds: 550),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => CircularProgressIndicator(
                value: value,
                strokeWidth: stroke,
                strokeCap: StrokeCap.round,
                backgroundColor: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                valueColor: AlwaysStoppedAnimation(_color),
              ),
            ),
          ),
          Text(
            '$percent%',
            style: TextStyle(
              fontSize: size * 0.26,
              fontWeight: FontWeight.w800,
              color: _color,
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of the completion checklist.
class CompletionChecklistRow extends StatelessWidget {
  final ProfileFieldState state;

  /// Null for coming-soon rows, which are informational only.
  final VoidCallback? onTap;

  const CompletionChecklistRow({super.key, required this.state, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final soon = !state.spec.isActive;

    final Widget leading;
    if (soon) {
      leading = Icon(Icons.lock_clock_rounded, size: 20, color: tertiary);
    } else if (state.complete) {
      leading = const Icon(Icons.check_circle_rounded,
          size: 20, color: AppTheme.successGreen);
    } else {
      leading = Icon(Icons.circle_outlined, size: 20, color: muted);
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.spec.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: soon
                          ? tertiary
                          : (isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary),
                    ),
                  ),
                  if (soon) ...[
                    const SizedBox(height: 2),
                    Text('Coming soon',
                        style: TextStyle(fontSize: 12, color: tertiary)),
                  ] else if (!state.complete) ...[
                    const SizedBox(height: 2),
                    Text(state.spec.hint,
                        style: TextStyle(fontSize: 12, color: muted)),
                  ],
                ],
              ),
            ),
            if (onTap != null && !state.complete)
              Icon(Icons.chevron_right, size: 20, color: muted),
          ],
        ),
      ),
    );
  }
}

/// Section container used by the Professional Profile — a titled card of rows.
class ProfileSectionCard extends StatelessWidget {
  final String title;
  final String? caption;
  final List<Widget> children;

  const ProfileSectionCard({
    super.key,
    required this.title,
    this.caption,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
              ),
              if (caption != null) ...[
                const SizedBox(height: 2),
                Text(caption!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

/// One editable / read-only row inside a [ProfileSectionCard].
///
/// A row with `onTap == null` renders as read-only and never invites a tap —
/// that is how Email and Member Since are presented, and how Phone is
/// presented when its only action is "managed elsewhere".
class ProfileFieldRow extends StatelessWidget {
  final IconData icon;
  final String label;

  /// The current value, or null when empty.
  final String? value;

  /// Shown instead of [value] when empty ("Add a short intro").
  final String emptyHint;

  /// Small muted note under the value ("Managed in Account").
  final String? note;

  final VoidCallback? onTap;
  final bool showDivider;

  /// Marks a value the user should revisit (legacy free-text profession).
  final bool needsAttention;

  const ProfileFieldRow({
    super.key,
    required this.icon,
    required this.label,
    this.value,
    this.emptyHint = 'Not set',
    this.note,
    this.onTap,
    this.showDivider = true,
    this.needsAttention = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final hasValue = (value ?? '').trim().isNotEmpty;

    return Column(
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: muted),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: TextStyle(fontSize: 12, color: muted)),
                      const SizedBox(height: 3),
                      Text(
                        hasValue ? value!.trim() : emptyHint,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: hasValue ? primary : tertiary,
                        ),
                      ),
                      if (note != null) ...[
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Icon(
                              needsAttention
                                  ? Icons.error_outline_rounded
                                  : Icons.lock_outline_rounded,
                              size: 13,
                              color: needsAttention ? AppTheme.warningOrange : tertiary,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                note!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: needsAttention
                                      ? AppTheme.warningOrange
                                      : tertiary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Icon(Icons.chevron_right, size: 20, color: muted),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (showDivider)
          Divider(
            height: 1,
            thickness: 1,
            indent: 50,
            color: (isDark ? AppTheme.darkBorder : AppTheme.lightBorder)
                .withValues(alpha: 0.6),
          ),
      ],
    );
  }
}

/// Bottom-sheet chrome shared by every focused profile editor: grab handle,
/// title, optional subtitle, keyboard-aware padding. Keeps the editors
/// themselves to just their field + save button.
class ProfileEditorSheet extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;

  const ProfileEditorSheet({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
              const SizedBox(height: 20),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline error banner used by the editors — same shape as the rest of the app.
class InlineErrorBanner extends StatelessWidget {
  final String message;
  const InlineErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppTheme.errorRed.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: AppTheme.errorRed, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.errorRed, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Convenience: the resolved profession, or null. Used by gates and headers
/// that need the object rather than the label.
Profession? resolvedProfession(String? stored) =>
    ProfessionRegistry.instance.resolve(stored);
