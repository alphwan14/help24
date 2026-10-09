import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/chat_sync.dart';
import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';

/// OFFLINE IS A STATUS, NOT AN ERROR.
///
/// The words for [ChatSyncPhase], or null when there is nothing to say. Kept
/// to two phrases so they read the same on every chat surface.
String? chatSyncLabel(ChatSyncPhase phase) => switch (phase) {
      ChatSyncPhase.offline => 'Waiting for network',
      ChatSyncPhase.connecting => 'Connecting…',
      ChatSyncPhase.idle => null,
    };

/// How long "Connecting…" must have been true before it is shown. A healthy
/// launch syncs in well under this, and a line that appears and vanishes in
/// 300 ms is noise, not information.
const Duration chatConnectingGrace = Duration(milliseconds: 900);

/// [ChatSync.phase] with "Connecting…" held back for [chatConnectingGrace].
/// "Waiting for network" shows at once: no network is never a blip.
class ChatSyncPhaseBuilder extends StatefulWidget {
  const ChatSyncPhaseBuilder({super.key, required this.builder, this.phase});

  final Widget Function(BuildContext context, String? label) builder;

  /// Test seam; defaults to [ChatSync.instance.phase].
  final ValueListenable<ChatSyncPhase>? phase;

  @override
  State<ChatSyncPhaseBuilder> createState() => _ChatSyncPhaseBuilderState();
}

class _ChatSyncPhaseBuilderState extends State<ChatSyncPhaseBuilder> {
  late final ValueListenable<ChatSyncPhase> _phase = widget.phase ?? ChatSync.instance.phase;
  Timer? _grace;
  String? _label;

  @override
  void initState() {
    super.initState();
    _phase.addListener(_onPhase);
    _onPhase();
  }

  void _onPhase() {
    final phase = _phase.value;
    _grace?.cancel();
    if (phase == ChatSyncPhase.connecting && _label == null) {
      _grace = Timer(chatConnectingGrace, () {
        if (mounted && _phase.value == ChatSyncPhase.connecting) {
          setState(() => _label = chatSyncLabel(ChatSyncPhase.connecting));
        }
      });
      return;
    }
    final next = chatSyncLabel(phase);
    if (next != _label && mounted) setState(() => _label = next);
  }

  @override
  void dispose() {
    _grace?.cancel();
    _phase.removeListener(_onPhase);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _label);
}

/// The Messages tab's line under its title: "Waiting for network", then
/// "Connecting…", then nothing. Content stays on screen throughout.
class ChatSyncStatusLine extends StatelessWidget {
  const ChatSyncStatusLine({super.key, this.phase});

  final ValueListenable<ChatSyncPhase>? phase;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ChatSyncPhaseBuilder(
      phase: phase,
      builder: (context, label) => AnimatedSize(
        duration: AppMotion.transition,
        alignment: Alignment.topLeft,
        child: label == null
            ? const SizedBox(width: double.infinity)
            : Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      ExcludeSemantics(
                        child: Icon(
                          label == chatSyncLabel(ChatSyncPhase.offline)
                              ? AppIcons.noConnection
                              : AppIcons.refresh,
                          size: 14,
                          color: c.contentTertiary,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: c.contentSecondary,
                                fontWeight: FontWeight.w500,
                              ),
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
