import 'package:flutter/material.dart';

import '../models/post_model.dart';
import '../services/application_service.dart';
import '../services/post_service.dart';
import '../theme/app_icons.dart';
import '../theme/tokens.dart';
import '../utils/format_utils.dart';
import '../utils/post_ownership.dart';
import '../utils/time_utils.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/primitives.dart';
import 'post_detail_screen.dart';

/// APPLIED — the work you asked for, and what came of it.
///
/// ── The gap this closes ─────────────────────────────────────────────────
/// `ApplicationService.getMyApplications` has been called on every sign-in for
/// as long as the app has existed, but only its POST IDS were kept — enough to
/// make a feed card say "Applied", and nothing more. The list itself was
/// thrown away. So a provider could apply to a dozen jobs and then have no way,
/// anywhere in the product, to see what they had applied for or whether anyone
/// had decided. The one surface that mentioned applications
/// (`ApplicationsScreen`) is the OWNER's — who applied to *my* post — which is
/// the opposite side of the same table.
///
/// ── Why this needed no backend change ───────────────────────────────────
/// Both halves already existed and are already in production use:
/// `ApplicationService.getMyApplications` for what I sent, and
/// `PostService.fetchPostsByIds` — the query the Saved shortlist runs — for
/// the listings themselves. The OUTCOME is not stored on the application at
/// all; it is derived from the post's own lifecycle by
/// [applicationOutcomeFor], so this screen and the owner's decision screen can
/// never disagree about who was hired.
///
/// ── Ordering ────────────────────────────────────────────────────────────
/// Live first — a decision you can still influence, or a job you are actually
/// doing — then newest application first within each group. Strict recency put
/// a job you lost three weeks ago above one you are currently being paid for.
///
/// ── Listings that are gone ──────────────────────────────────────────────
/// `fetchPostsByIds` excludes archived posts, and an application row outlives
/// the post it points at. Those cannot be rendered — the application carries no
/// title, only an id and a price — so they are counted in a footnote rather
/// than dropped silently. "I applied to five things and this shows three" is
/// the confusion that footnote exists to prevent.
class MyApplicationsScreen extends StatefulWidget {
  final String userId;

  /// Render the BODY only — the Activity tab supplies its own chrome.
  /// See `MyPostsScreen.embedded`.
  final bool embedded;

  const MyApplicationsScreen({
    super.key,
    required this.userId,
    this.embedded = false,
  });

  @override
  State<MyApplicationsScreen> createState() => _MyApplicationsScreenState();
}

/// One application paired with the listing it was sent to.
class _AppliedItem {
  _AppliedItem({
    required this.application,
    required this.post,
    required this.outcome,
  });

  final Application application;
  final PostModel post;
  final ApplicationOutcome outcome;
}

class _MyApplicationsScreenState extends State<MyApplicationsScreen> {
  List<_AppliedItem> _items = const [];

  /// Applications whose listing no longer resolves (archived or deleted).
  /// Counted, never faked — see the class doc.
  int _unresolved = 0;

  bool _loading = true;
  String? _error;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final applications =
          await ApplicationService.getMyApplications(widget.userId);

      // Keep only the newest application per post. The unique constraint makes
      // duplicates impossible going forward, but rows written before it landed
      // would otherwise render the same listing twice.
      final newestByPost = <String, Application>{};
      for (final a in applications) {
        if (a.postId.isEmpty) continue;
        final existing = newestByPost[a.postId];
        if (existing == null || a.timestamp.isAfter(existing.timestamp)) {
          newestByPost[a.postId] = a;
        }
      }

      if (newestByPost.isEmpty) {
        if (!mounted) return;
        setState(() {
          _items = const [];
          _unresolved = 0;
          _loading = false;
          _error = null;
          _offline = false;
        });
        return;
      }

      final posts =
          await PostService.fetchPostsByIds(newestByPost.keys.toList());
      final byId = {for (final p in posts) p.id: p};

      final items = <_AppliedItem>[];
      for (final entry in newestByPost.entries) {
        final post = byId[entry.key];
        if (post == null) continue;
        items.add(_AppliedItem(
          application: entry.value,
          post: post,
          outcome: applicationOutcomeFor(
            status: post.status,
            selectedProviderUserId: post.selectedProviderUserId,
            viewerUserId: widget.userId,
          ),
        ));
      }

      items.sort((a, b) {
        final aLive = applicationOutcomeIsLive(a.outcome);
        final bLive = applicationOutcomeIsLive(b.outcome);
        if (aLive != bLive) return aLive ? -1 : 1;
        return b.application.timestamp.compareTo(a.application.timestamp);
      });

      if (!mounted) return;
      setState(() {
        _items = items;
        _unresolved = newestByPost.length - items.length;
        _loading = false;
        _error = null;
        _offline = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _offline = e is PostServiceException && e.isNetworkError;
        _error = e is PostServiceException
            ? e.message
            : 'We could not load your applications.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Applied')),
      body: body,
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const LoadingView();

    if (_error != null) {
      if (_offline) return OfflineEmptyView(onRetry: _load);
      return ErrorRetryView(message: _error!, onRetry: _load);
    }

    if (_items.isEmpty && _unresolved == 0) {
      return const EmptyStateView(
        icon: AppIcons.application,
        title: 'You have not applied to anything yet',
        subtitle: 'When you respond to a request or a job, it appears here '
            'with whatever the poster decides.',
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.gutter, AppSpace.sm,
            AppSpace.gutter, AppSpace.fabClearance),
        children: [
          for (final item in _items)
            _AppliedRow(
              item: item,
              onOpen: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => PostDetailScreen(post: item.post)),
              ),
            ),
          if (_unresolved > 0) _UnresolvedNote(count: _unresolved),
        ],
      ),
    );
  }
}

/// One applied listing. A compact card, not a feed card: the question here is
/// "what happened to this", not "should I respond to this", and answering the
/// second one is the feed card's entire job.
class _AppliedRow extends StatelessWidget {
  const _AppliedRow({required this.item, required this.onOpen});

  final _AppliedItem item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final post = item.post;
    final offered = item.application.proposedPrice;

    return AppCard(
      onTap: onOpen,
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  post.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: AppSpace.md),
              _OutcomeChip(outcome: item.outcome),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          MetaLine([
            post.location,
            'Applied ${formatRelativeTime(item.application.timestamp)}',
          ]),
          // Only shown when the applicant actually named a figure. A bare
          // "KES 0" would read as an offer to work for nothing.
          if (offered > 0) ...[
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Text(
                  'Your offer',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: c.contentSecondary),
                ),
                const SizedBox(width: AppSpace.sm),
                MoneyLabel(formatPriceDisplay(offered)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The outcome, in the one place the eye lands after the title.
class _OutcomeChip extends StatelessWidget {
  const _OutcomeChip({required this.outcome});

  final ApplicationOutcome outcome;

  @override
  Widget build(BuildContext context) {
    // Tone carries the meaning; the label carries the detail.
    //
    // `notSelected` is deliberately NEUTRAL rather than critical — losing a job
    // is an ordinary outcome, not an error, and a red chip on a list a provider
    // reads every week would make the whole screen feel like a scolding.
    //
    // SOLID IS RESERVED FOR `disputed`, and the device pass is why. `hired` was
    // solid first, on the reasoning that being hired is the outcome that
    // matters — but on a real account seven of the nine rows came back hired,
    // and seven solid green chips are not an emphasis, they are the
    // background. AppChip says this in its own doc: "a screen with two solid
    // chips has none." A dispute is the one state here that is both rare and
    // urgent, so it is the one that gets to shout.
    final (tone, solid) = switch (outcome) {
      ApplicationOutcome.pending => (ChipTone.info, false),
      ApplicationOutcome.hired => (ChipTone.positive, false),
      ApplicationOutcome.completed => (ChipTone.neutral, false),
      ApplicationOutcome.disputed => (ChipTone.critical, true),
      ApplicationOutcome.notSelected => (ChipTone.neutral, false),
      ApplicationOutcome.closed => (ChipTone.neutral, false),
    };
    return AppChip(
      label: applicationOutcomeLabel(outcome),
      tone: tone,
      solid: solid,
    );
  }
}

/// Applications whose listing is no longer retrievable.
class _UnresolvedNote extends StatelessWidget {
  const _UnresolvedNote({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
      child: Text(
        count == 1
            ? '1 listing you applied to is no longer available.'
            : '$count listings you applied to are no longer available.',
        textAlign: TextAlign.center,
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: c.contentTertiary),
      ),
    );
  }
}
