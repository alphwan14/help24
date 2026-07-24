import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../services/application_service.dart';
import '../services/jobs_service.dart';
import '../services/post_service.dart';
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
  // Tracks which provider is currently being accepted (shows spinner on that card only).
  String? _accepting;
  // Once a provider is accepted we lock the entire list.
  String? _acceptedProviderId;

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
      if (_acceptedProviderId == null) {
        final post = await PostService.getPostById(widget.postId);
        serverSelected = post?.selectedProviderUserId;
      }
      if (!mounted) return;
      setState(() {
        _applications = apps;
        if (serverSelected != null && serverSelected.isNotEmpty) {
          _acceptedProviderId = serverSelected;
        }
        _loading = false;
        if (!silent) _error = null;
      });
      if (silent) debugPrint('[APPLICATIONS][REFRESH] Reloaded ${apps.length} applications');
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _error = 'Failed to load applications. Pull down to retry.';
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
                  Icon(Icons.cloud_off_rounded, size: 48, color: AppTheme.errorRed.withValues(alpha: 0.7)),
                  const SizedBox(height: 16),
                  Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: textSecondary)),
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
      itemCount: _applications.length,
      itemBuilder: (context, index) {
        final app = _applications[index];
        return ApplicantCard(
          application: app,
          isSelected: app.applicantUserId == _acceptedProviderId,
          isAccepting: _accepting == app.applicantUserId,
          canAccept: _acceptedProviderId == null &&
              _accepting == null &&
              app.applicantUserId.isNotEmpty,
          onAccept: () => _accept(app),
          onMessage: () => _openChatWith(app),
        );
      },
    );
  }
}
