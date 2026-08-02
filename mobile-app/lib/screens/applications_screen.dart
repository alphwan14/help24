import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../services/application_service.dart';
import '../services/jobs_service.dart';
import '../services/post_service.dart';
import '../services/reputation_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_mapper.dart';
import '../widgets/applicant_card.dart';
import '../widgets/loading_empty_offline.dart';
import 'messages_screen.dart';

/// Dedicated screen for a post owner to view and manage applications.
/// Only the post author should navigate here.
class ApplicationsScreen extends StatefulWidget {
  final String postId;
  final String postTitle;
  final String authorUserId;

  const ApplicationsScreen({
    super.key,
    required this.postId,
    required this.postTitle,
    required this.authorUserId,
  });

  @override
  State<ApplicationsScreen> createState() => _ApplicationsScreenState();
}

class _ApplicationsScreenState extends State<ApplicationsScreen> {
  List<Application> _applications = [];
  bool _loading = true;
  String? _error;

  /// The load itself failed because the device is offline (as opposed to the
  /// server failing) — changes the icon and the wording, not the layout.
  bool _errorIsOffline = false;

  /// Applications loaded, but their trust data could not be reached. The list
  /// is still useful (names, messages, prices) so it is still shown — with one
  /// honest banner above it rather than a repeated apology on every card.
  bool _reputationOffline = false;
  // Tracks which provider is currently being accepted (shows spinner on that card only).
  String? _accepting;
  // Once a provider is accepted we lock the entire list.
  String? _acceptedProviderId;

  /// Whether accepting an applicant starts the escrow lifecycle. Requests only
  /// — see `_ApplicantsSection.canSelectProvider` in post_detail_screen.dart
  /// for why an employment job must not enter it. Assumed true until the post
  /// is loaded, then corrected; the Accept button only renders once
  /// [_acceptedProviderId] has been resolved by that same load.
  bool _canSelectProvider = true;

  RealtimeChannel? _realtimeChannel;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _realtimeChannel?.unsubscribe();
    super.dispose();
  }

  void _subscribeRealtime() {
    _realtimeChannel = Supabase.instance.client
        .channel('applications:${widget.postId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'applications',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'post_id',
            value: widget.postId,
          ),
          callback: (payload) {
            debugPrint('[APPLICATIONS][REALTIME] New application on postId=${widget.postId}');
            _load(silent: true);
          },
        )
        .subscribe();
    debugPrint('[APPLICATIONS][REFRESH] Realtime subscribed for postId=${widget.postId}');
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final apps = await ApplicationService.getApplicationsForPost(widget.postId);
      // Hydrate the "already assigned" lock from the server, so reopening this
      // screen after a provider was chosen reflects that state instead of
      // re-inviting a selection (which then hit a conflict). Only needed until
      // we know of a selection.
      String? serverSelected;
      PostModel? post;
      if (_acceptedProviderId == null) {
        post = await PostService.getPostById(widget.postId);
        serverSelected = post?.selectedProviderUserId;
      }

      // ── The applicant list is ONE thing, so it loads as one thing ──────────
      // Every card's trust line comes from this single request, resolved BEFORE
      // the list is put on screen. Previously each card fetched its own, which
      // is why a list of eight arrived as eight separate reveals and why a
      // strained connection produced a handful of "Reputation unavailable"
      // cards next to loaded ones — the same screen telling the user two
      // different stories about the same network.
      final warmth = await ReputationService.warmAll(
        apps.map((a) => a.applicantUserId),
      );

      if (!mounted) return;
      setState(() {
        _applications = apps;
        if (post != null) {
          _canSelectProvider = post.type == PostType.request;
        }
        if (serverSelected != null && serverSelected.isNotEmpty) {
          _acceptedProviderId = serverSelected;
        }
        _loading = false;
        _reputationOffline = warmth == ReputationOutcome.offline;
        if (!silent) _error = null;
      });
      if (silent) debugPrint('[APPLICATIONS][REFRESH] Reloaded ${apps.length} applications');
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        // One mapped message rather than one guess: an unreachable server and a
        // phone with no signal are different problems and read differently.
        final failure = ErrorMapper.toFailure(e, context: ErrorContext.loadContent);
        setState(() {
          _error = failure.message;
          _errorIsOffline = failure.isOffline;
          _loading = false;
        });
      }
    }
  }

  Future<void> _accept(Application app) async {
    final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
    if (currentUserId.isEmpty) return;
    if (_acceptedProviderId != null) return; // already accepted someone

    setState(() => _accepting = app.applicantUserId);
    try {
      await JobsService.selectProvider(
        postId: widget.postId,
        providerId: app.applicantUserId,
        clientUserId: currentUserId,
      );

      if (!mounted) return;
      setState(() {
        _acceptedProviderId = app.applicantUserId;
        _accepting = null;
      });

      // Show success feedback then open chat.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Flexible(
              child: Text('${app.applicantName.isNotEmpty ? app.applicantName : 'Provider'} selected! Opening chat…'),
            ),
          ]),
          backgroundColor: AppTheme.successGreen,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          duration: const Duration(seconds: 2),
        ),
      );

      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;

      _openChatWith(app);
    } catch (e) {
      if (!mounted) return;
      setState(() => _accepting = null);
      debugPrint('[Applications] accept provider failed: $e');
      final msg = ErrorMapper.toMessage(e, context: ErrorContext.selectProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Flexible(child: Text(msg)),
          ]),
          backgroundColor: AppTheme.errorRed,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  void _openChatWith(Application app) {
    final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
    if (currentUserId.isEmpty || app.applicantUserId.isEmpty) return;
    final conv = Conversation(
      id: '',
      participantId: app.applicantUserId,
      userName: app.applicantName.isNotEmpty ? app.applicantName : 'Provider',
      userAvatar: app.applicantAvatarUrl,
      lastMessage: '',
      lastMessageTime: DateTime.now(),
      postId: widget.postId,
      postTitle: widget.postTitle,
    );
    // Pop back to root tab nav (clears sheet + ApplicationsScreen from stack),
    // then push ChatScreen so back navigation goes cleanly to the home screen.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => ChatScreen(conversation: conv, currentUserId: currentUserId),
      ),
      (route) => route.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Applications',
              style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
            if (widget.postTitle.isNotEmpty)
              Text(
                widget.postTitle,
                style: TextStyle(color: textSecondary, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          if (!_loading)
            IconButton(
              icon: Icon(Icons.refresh_rounded, color: textPrimary),
              onPressed: _load,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: ReconnectListener(
        onReconnect: () => _load(),
        child: RefreshIndicator(
          onRefresh: _load,
          color: AppTheme.primaryAccent,
          child: _buildBody(isDark, textPrimary, textSecondary),
        ),
      ),
    );
  }

  Widget _buildBody(bool isDark, Color textPrimary, Color textSecondary) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppTheme.primaryAccent));
    }

    if (_error != null) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.3),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  Icon(
                    _errorIsOffline ? Icons.wifi_off_rounded : Icons.cloud_off_rounded,
                    size: 48,
                    color: AppTheme.errorRed.withValues(alpha: 0.7),
                  ),
                  const SizedBox(height: 16),
                  Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: textSecondary)),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_applications.isEmpty) {
      return ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.3),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  Icon(Icons.inbox_rounded, size: 52, color: textSecondary.withValues(alpha: 0.4)),
                  const SizedBox(height: 16),
                  Text(
                    'No applications yet.',
                    style: TextStyle(color: textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Providers who apply to your post will appear here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      // One extra row for the trust-data banner, when there is one to show.
      itemCount: _applications.length + (_reputationOffline ? 1 : 0),
      itemBuilder: (context, index) {
        if (_reputationOffline) {
          if (index == 0) return _ReputationOfflineBanner(isDark: isDark);
          index -= 1;
        }
        final app = _applications[index];
        return ApplicantCard(
          application: app,
          isSelected: app.applicantUserId == _acceptedProviderId,
          isAccepting: _accepting == app.applicantUserId,
          canAccept: _canSelectProvider &&
              _acceptedProviderId == null &&
              _accepting == null &&
              app.applicantUserId.isNotEmpty,
          onAccept: () => _accept(app),
          onMessage: () => _openChatWith(app),
        );
      },
    );
  }
}

/// Said ONCE, above the list, instead of on every card.
///
/// The applications themselves came from cache or from the server and are real;
/// only the trust signals are missing. Repeating that on each card made a
/// connectivity problem look like eight separate problems with eight separate
/// people.
class _ReputationOfflineBanner extends StatelessWidget {
  final bool isDark;

  const _ReputationOfflineBanner({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.warningOrange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warningOrange.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.wifi_off_rounded, size: 18, color: AppTheme.warningOrange),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "You're offline. Ratings and job history will fill in once you reconnect.",
              style: TextStyle(color: muted, fontSize: 12.5, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
