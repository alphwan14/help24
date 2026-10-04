import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../models/chat_job_stage.dart';
import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';
import 'chat_bubbles.dart' show ChatHug;

// =============================================================================
// THE CHAT'S CHROME: header, pinned job bar, offline banner, composer, the
// scroll-down button and quick replies.
//
// Sizes are minimums and grow with the system text size; nothing that holds
// text has a fixed height. Every icon-only control is at least 44×44 and says
// what it does to a screen reader.
// =============================================================================

// ── Header ───────────────────────────────────────────────────────────────────

/// Back, the other person, and the overflow menu (Report lives there).
///
/// The second line says who they are on Help24 — "Plumber · ★ 4.8 · 34 jobs",
/// "Customer · Bamburi, Mombasa" — rather than when they last opened the app;
/// "typing…" takes it over while they write.
class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.name,
    required this.avatarUrl,
    required this.onBack,
    required this.menu,
    this.subtitle,
    this.typing = false,
    this.online = false,
    this.badge,
  });

  final String name;
  final String avatarUrl;
  final String? subtitle;
  final bool typing;
  final bool online;
  final VoidCallback onBack;

  /// The overflow menu button.
  final Widget menu;

  /// Shown after the name (the earned verification tick).
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final initial = name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: ChatGeometry.headerHeight),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 2, end: 2),
        child: Row(
          children: [
            Semantics(
              button: true,
              label: 'Back',
              excludeSemantics: true,
              child: IconButton(
                onPressed: onBack,
                icon: Icon(AppIcons.back, size: 22, color: c.text),
                constraints: const BoxConstraints.tightFor(
                  width: ChatGeometry.minTouch,
                  height: ChatGeometry.minTouch,
                ),
                padding: EdgeInsets.zero,
              ),
            ),
            _Avatar(url: avatarUrl, initial: initial, online: online),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              height: 21 / 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                              color: c.text,
                            ),
                          ),
                        ),
                        if (badge != null) ...[const SizedBox(width: 4), badge!],
                      ],
                    ),
                    if (typing || (subtitle != null && subtitle!.isNotEmpty))
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: AnimatedSwitcher(
                          duration: AppMotion.transition,
                          child: Text(
                            typing ? 'typing…' : subtitle!,
                            key: ValueKey(typing ? 'typing' : subtitle),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 16 / 12.5,
                              fontWeight: typing ? FontWeight.w600 : FontWeight.w400,
                              color: typing ? c.accentText : c.textSecondary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            menu,
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.initial, required this.online});

  final String url;
  final String initial;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    const size = ChatGeometry.headerAvatar;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        initial,
        textScaler: TextScaler.noScaling, // fixed-size avatar, a glyph not text
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.textSecondary),
      ),
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipOval(
              child: url.isEmpty
                  ? placeholder
                  : CachedNetworkImage(
                      imageUrl: url,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                      placeholder: (_, __) => placeholder,
                      errorWidget: (_, __, ___) => placeholder,
                    ),
            ),
            if (online)
              PositionedDirectional(
                end: -1,
                bottom: -1,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: c.successBar,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.bg, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The header's overflow button: 44×44, labelled, Report inside.
class ChatMenuButton<T> extends StatelessWidget {
  const ChatMenuButton({super.key, required this.itemBuilder, required this.onSelected});

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final app = AppColors.of(context);
    return PopupMenuButton<T>(
      tooltip: 'More options, including Report',
      icon: Icon(AppIcons.more, size: 22, color: c.iconSecondary),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 220),
      position: PopupMenuPosition.under,
      color: app.surface,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.lgAll,
        side: BorderSide(color: app.borderHairline, width: 0.5),
      ),
      itemBuilder: itemBuilder,
      onSelected: onSelected,
    );
  }
}

// ── Pinned job bar ───────────────────────────────────────────────────────────

/// What this job is and where its money is, one stage at a time.
///
/// Replaces "Tap to view post details". Tapping the bar outside its button
/// still opens the job, as before; the button is the next step for whoever is
/// looking — Pay, I've arrived, Mark complete, Rate.
class ChatJobBar extends StatelessWidget {
  const ChatJobBar({
    super.key,
    required this.state,
    this.onOpen,
    this.onAction,
    this.busy = false,
  });

  final ChatJobBarState state;
  final VoidCallback? onOpen;
  final VoidCallback? onAction;

  /// The bar's own open is in flight (the job is loading).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final (Color tileFill, Color tileIcon, IconData icon) = switch (state.tile) {
      ChatJobTile.job => (c.warningTile, c.accentText, AppIcons.fileDocument),
      ChatJobTile.money => (c.warningTile, c.accentText, AppIcons.paymentNumber),
      ChatJobTile.tool => (c.warningTile, c.accentText, AppIcons.completedWork),
      ChatJobTile.lock => (c.successTile, c.success, AppIcons.escrow),
      ChatJobTile.check => (c.successTile, c.success, AppIcons.successFilled),
      ChatJobTile.alert => (c.dangerTile, c.danger, AppIcons.messageNotSent),
    };
    final statusColor = switch (state.tone) {
      ChatJobTone.neutral => c.textSecondary,
      ChatJobTone.success => c.success,
      ChatJobTone.danger => c.danger,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: c.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.jobBarRadius)),
          side: BorderSide(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onOpen,
          child: Semantics(
            container: true,
            label: '${state.title}. ${state.status}. ${state.stageLabel}.',
            hint: onOpen == null ? null : 'Double tap to open the job',
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 10, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      ExcludeSemantics(
                        child: Container(
                          width: ChatGeometry.jobTile,
                          height: ChatGeometry.jobTile,
                          decoration: BoxDecoration(
                            color: tileFill,
                            borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.jobTileRadius)),
                          ),
                          child: busy
                              ? Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: CircularProgressIndicator(strokeWidth: 2, color: tileIcon),
                                )
                              : Icon(icon, size: 18, color: tileIcon),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ExcludeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                state.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 19 / 14,
                                  fontWeight: FontWeight.w600,
                                  color: c.text,
                                ),
                              ),
                              Row(
                                children: [
                                  if (state.tone != ChatJobTone.neutral) ...[
                                    Icon(
                                      state.tone == ChatJobTone.danger
                                          ? AppIcons.messageNotSent
                                          : (state.tile == ChatJobTile.lock ? AppIcons.escrow : AppIcons.check),
                                      size: 13,
                                      color: statusColor,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Flexible(
                                    child: Text(
                                      state.status,
                                      // Two lines, not one: at large text sizes the stage
                                      // ("KES 1,100 held by Help24") is the fact the bar
                                      // exists to show, so it wraps rather than truncating.
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 12.5, height: 17 / 12.5, color: statusColor),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _JobAction(
                        label: state.actionLabel,
                        primary: state.primary,
                        onTap: onAction,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ExcludeSemantics(
                    child: Row(
                      children: [
                        for (var i = 0; i < state.segments.length; i++) ...[
                          if (i > 0) const SizedBox(width: ChatGeometry.progressGap),
                          Expanded(
                            child: AnimatedContainer(
                              duration: AppMotion.transition,
                              height: ChatGeometry.progressHeight,
                              decoration: BoxDecoration(
                                color: switch (state.segments[i]) {
                                  ChatJobSegment.done => c.successBar,
                                  ChatJobSegment.current => c.progressCurrent,
                                  ChatJobSegment.track => c.progressTrack,
                                  ChatJobSegment.danger => c.danger,
                                },
                                borderRadius: AppRadius.pillAll,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar's button: 34 tall, a 44 tall target.
class _JobAction extends StatelessWidget {
  const _JobAction({required this.label, required this.primary, required this.onTap});

  final String label;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: ChatGeometry.minTouch),
          child: Center(
            widthFactor: 1,
            child: Container(
              constraints: const BoxConstraints(minHeight: ChatGeometry.jobButtonHeight),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: primary ? c.accent : c.surface,
                borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.jobButtonRadius)),
              ),
              child: ChatHug(
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    height: 16 / 13,
                    fontWeight: FontWeight.w600,
                    color: primary ? c.onAccent : c.text,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Offline banner ───────────────────────────────────────────────────────────

class ChatOfflineBanner extends StatelessWidget {
  const ChatOfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: c.warningTile,
            borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.bannerRadius)),
          ),
          child: Row(
            children: [
              ExcludeSemantics(child: Icon(AppIcons.noConnection, size: 18, color: c.onWarningTile)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "You're offline. Messages will send when you reconnect.",
                  style: TextStyle(fontSize: 13, height: 18 / 13, color: c.onWarningTile),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Composer ─────────────────────────────────────────────────────────────────

/// The quietest thing on the screen: a borderless pill with attach and
/// camera inside, and Send — which only turns amber when there is something
/// to send.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.onAttach,
    required this.onCamera,
    required this.onSend,
    this.busy = false,
    this.maxLines = 5,
  });

  final TextEditingController controller;
  final VoidCallback onAttach;
  final VoidCallback onCamera;
  final VoidCallback onSend;

  /// Something outside the field is being sent (a journey starting).
  final bool busy;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    const none = InputBorder.none;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ChatGeometry.sidePadding, 6, ChatGeometry.sidePadding, 8,
      ),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final hasText = value.text.trim().isNotEmpty;
          final canSend = hasText && !busy;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(minHeight: ChatGeometry.composerHeight),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.composerRadius)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _PillIcon(
                        icon: AppIcons.attach,
                        label: 'Attach a photo, file or location',
                        onTap: onAttach,
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: TextField(
                            controller: controller,
                            minLines: 1,
                            maxLines: maxLines,
                            textInputAction: TextInputAction.newline,
                            keyboardType: TextInputType.multiline,
                            textCapitalization: TextCapitalization.sentences,
                            cursorColor: c.accentText,
                            style: TextStyle(fontSize: 15, height: 20 / 15, color: c.text),
                            // Every border spelled out: InputDecorationTheme
                            // fills in any that are left null, which is how the
                            // old composer came to wear a 2 px focus outline
                            // brighter than any message on screen.
                            decoration: InputDecoration(
                              hintText: 'Message',
                              hintStyle: TextStyle(fontSize: 15, height: 20 / 15, color: c.textSecondary),
                              filled: false,
                              border: none,
                              enabledBorder: none,
                              focusedBorder: none,
                              disabledBorder: none,
                              errorBorder: none,
                              focusedErrorBorder: none,
                              isDense: true,
                              contentPadding: const EdgeInsets.fromLTRB(4, 12, 4, 12),
                            ),
                            onSubmitted: (_) => onSend(),
                          ),
                        ),
                      ),
                      if (!hasText)
                        _PillIcon(icon: AppIcons.camera, label: 'Take a photo', onTap: onCamera),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _SendButton(enabled: canSend, busy: busy, onTap: onSend),
            ],
          );
        },
      ),
    );
  }
}

/// 38 px of drawn circle inside a 44 px target, bottom-aligned so it stays
/// put while the field grows.
class _PillIcon extends StatelessWidget {
  const _PillIcon({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Container(
        // Centred in the 46 px pill: (46 − 44) / 2 above and below.
        margin: const EdgeInsets.symmetric(vertical: (ChatGeometry.composerHeight - ChatGeometry.minTouch) / 2),
        width: ChatGeometry.minTouch,
        height: ChatGeometry.minTouch,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            onTap: onTap,
            radius: ChatGeometry.composerIcon / 2,
            child: Center(child: Icon(icon, size: 22, color: c.iconSecondary)),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.busy, required this.onTap});

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Send',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: AppMotion.state,
          curve: AppMotion.enter,
          width: ChatGeometry.sendDiameter,
          height: ChatGeometry.sendDiameter,
          decoration: BoxDecoration(
            color: enabled ? c.accent : c.surface,
            shape: BoxShape.circle,
          ),
          child: busy
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.accentText),
                )
              : Icon(AppIcons.sendMessage, size: 21, color: enabled ? c.onAccent : c.iconDisabled),
        ),
      ),
    );
  }
}

// ── Scroll to latest ─────────────────────────────────────────────────────────

/// Back to the newest message, with how many arrived while you were away.
class ChatScrollToLatest extends StatelessWidget {
  const ChatScrollToLatest({super.key, required this.onTap, this.unread = 0});

  final VoidCallback onTap;
  final int unread;

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return Semantics(
      button: true,
      label: unread > 0 ? 'Jump to latest message, $unread new' : 'Jump to latest message',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: ChatGeometry.minTouch,
          height: ChatGeometry.minTouch,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Container(
                width: ChatGeometry.scrollButtonDiameter,
                height: ChatGeometry.scrollButtonDiameter,
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.border),
                ),
                child: Icon(AppIcons.jumpToLatest, size: 24, color: c.text),
              ),
              if (unread > 0)
                PositionedDirectional(
                  top: -4,
                  end: -2,
                  child: Container(
                    constraints: BoxConstraints(
                      minWidth: math.max(18, scaler.scale(11) + 7),
                      minHeight: math.max(18, scaler.scale(11) + 7),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(color: c.accent, borderRadius: AppRadius.pillAll),
                    child: ChatHug(
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, height: 1, fontWeight: FontWeight.w700, color: c.onAccent),
                      ),
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

// ── Quick replies ────────────────────────────────────────────────────────────

/// One-tap replies for a provider on the way — "5 min away", "I'm at the
/// gate", "Running late" — above the composer while their journey is live.
class ChatQuickReplies extends StatelessWidget {
  const ChatQuickReplies({super.key, required this.replies, required this.onTap});

  final List<String> replies;
  final ValueChanged<String> onTap;

  static const List<String> onTheWay = ['5 min away', "I'm at the gate", 'Running late'];

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final chip = math.max(ChatGeometry.minTouch, scaler.scale(13.5) * 1.3 + 16);
    return SizedBox(
      height: chip + 6,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(ChatGeometry.sidePadding, 4, ChatGeometry.sidePadding, 2),
        itemCount: replies.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) => Semantics(
          button: true,
          label: 'Send: ${replies[i]}',
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              onTap(replies[i]);
            },
            child: Center(
              child: Container(
                constraints: const BoxConstraints(minHeight: ChatGeometry.quickReplyHeight),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  border: Border.all(color: c.border),
                  borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.quickReplyRadius)),
                ),
                child: ChatHug(
                  child: Text(
                    replies[i],
                    maxLines: 1,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: c.text),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
