import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:provider/provider.dart';
import '../models/attribute_display.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../services/application_service.dart';
import '../services/category_schema_service.dart';
import '../services/jobs_service.dart';
import '../services/mpesa_service.dart';
import '../services/saved_service.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_mapper.dart';
import '../utils/format_utils.dart';
import '../utils/payment_utils.dart';
import '../utils/phone_utils.dart';
import '../utils/time_utils.dart';
import '../widgets/applicant_card.dart';
import '../widgets/auth_guard.dart';
import '../widgets/post_flows.dart';
import '../widgets/reputation_widgets.dart';
import 'applications_screen.dart';
import 'approve_or_dispute_screen.dart';
import 'mark_complete_screen.dart';
import 'payment_screen.dart';

/// Production post detail — the conversion surface of Help24.
///
/// Replaces the old 85%-height discover bottom sheet AND the simplified
/// `_PostDetailPage` that chat used, so there is exactly ONE detail
/// implementation. Layout: media header → identity (type/urgency/time) →
/// title → price → author trust card → description → structured details →
/// payment protection → role-specific management (applicants / job status),
/// with a sticky bottom action bar carrying the single most relevant action
/// for the viewer's role and the post's state.
///
/// All business rules are inherited unchanged from the old sheet:
/// duplicate-apply guard, M-Pesa prechecks, payment-secured lock, provider
/// selection, job lifecycle actions, archive-on-delete.
class PostDetailScreen extends StatefulWidget {
  final PostModel post;

  const PostDetailScreen({super.key, required this.post});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  /// Local selection override — updated immediately after "Select" so the
  /// payment button appears without waiting for a feed reload.
  String? _selectedProviderId;

  /// Applied state — set by a one-shot background check or after submitting
  /// an offer. Drives the "Applied" state in the action bar.
  bool _hasApplied = false;
  bool _appliedChecked = false;

  JobCompletionStatus? _jobStatus;
  bool _jobStatusChecked = false;

  /// Bumped after returning from PaymentScreen so the payment button re-runs
  /// its status check (the old sheet closed itself before paying; this screen
  /// stays open, so it must refresh).
  int _paymentRefreshTick = 0;

  PostModel get post => widget.post;

  @override
  void initState() {
    super.initState();
    _selectedProviderId = post.selectedProviderUserId;
  }

  // One-shot checks mirror the old sheet: they run from build the first time
  // their preconditions hold (auth may arrive after the screen opens).
  void _runOneShotChecks(String currentUserId, bool isAuthor) {
    if (!_appliedChecked &&
        !isAuthor &&
        currentUserId.isNotEmpty &&
        post.type == PostType.request) {
      _appliedChecked = true;
      ApplicationService.hasApplied(post.id, currentUserId).then((applied) {
        if (applied && mounted) setState(() => _hasApplied = true);
      });
    }
    if (!_jobStatusChecked &&
        post.type == PostType.request &&
        _selectedProviderId != null) {
      _jobStatusChecked = true;
      _refreshJobStatus();
    }
  }

  void _refreshJobStatus() {
    JobsService.getJobStatus(post.id).then((s) {
      if (s != null && mounted) setState(() => _jobStatus = s);
    });
  }

  String get _aboutHeader => switch (post.type) {
        PostType.request => 'About this request',
        PostType.offer => 'About this service',
        PostType.job => 'About this job',
      };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Consumer2<AuthProvider, ConnectivityProvider>(
      builder: (context, auth, connectivity, _) {
        final currentUserId = auth.currentUserId ?? '';
        final isAuthor = currentUserId.isNotEmpty &&
            post.authorUserId.isNotEmpty &&
            post.authorUserId == currentUserId;
        final isOffline = connectivity.isOffline;

        final showPayButton = post.type == PostType.request &&
            isAuthor &&
            _selectedProviderId != null &&
            post.price > 0;

        final isSelectedProvider = post.type == PostType.request &&
            currentUserId.isNotEmpty &&
            _selectedProviderId != null &&
            _selectedProviderId == currentUserId &&
            !isAuthor;

        _runOneShotChecks(currentUserId, isAuthor);

        // Warm the shortlist ids so the bookmark renders its correct state.
        if (currentUserId.isNotEmpty) {
          SavedService.instance.ensureLoaded(currentUserId);
        }

        final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;

        return Scaffold(
          backgroundColor: bg,
          body: CustomScrollView(
            slivers: [
              _buildAppBar(context, isDark, isAuthor),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildIdentityRow(isDark),
                      const SizedBox(height: 14),
                      Text(
                        post.title,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                            ),
                      ),
                      const SizedBox(height: 10),
                      _buildCategoryRow(isDark),
                      const SizedBox(height: 18),
                      _PriceCard(post: post, isDark: isDark),
                      const SizedBox(height: 14),
                      _AuthorCard(
                        post: post,
                        isDark: isDark,
                        // Providers are savable from their service posts.
                        trailing: (post.type == PostType.offer &&
                                !isAuthor &&
                                post.authorUserId.isNotEmpty)
                            ? ListenableBuilder(
                                listenable: SavedService.instance,
                                builder: (context, _) {
                                  final saved = SavedService.instance
                                      .isProviderSaved(post.authorUserId);
                                  return SizedBox(
                                    height: 34,
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        AuthGuard.requireAuth(
                                          context,
                                          action: 'save this provider',
                                          onAuthenticated: () {
                                            final uid = context
                                                    .read<AuthProvider>()
                                                    .currentUserId ??
                                                '';
                                            SavedService.instance
                                                .toggleProvider(
                                                    uid, post.authorUserId);
                                          },
                                        );
                                      },
                                      icon: Icon(
                                        saved
                                            ? Icons.bookmark_rounded
                                            : Icons.bookmark_add_outlined,
                                        size: 15,
                                      ),
                                      label: Text(saved ? 'Saved' : 'Save'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: AppTheme.primaryAccent,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        textStyle: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  );
                                },
                              )
                            : null,
                      ),
                      if (post.description.trim().isNotEmpty) ...[
                        const SizedBox(height: 24),
                        _SectionHeader(title: _aboutHeader),
                        const SizedBox(height: 10),
                        _ExpandableText(text: post.description.trim(), isDark: isDark),
                      ],
                      ..._buildDetailsSection(isDark),
                      if (post.type == PostType.request && post.price > 0) ...[
                        const SizedBox(height: 24),
                        _PaymentProtectionCard(isDark: isDark),
                      ],
                      if (post.type == PostType.request && isAuthor) ...[
                        const SizedBox(height: 24),
                        _ApplicantsSection(
                          post: post,
                          isDark: isDark,
                          overrideSelectedId: _selectedProviderId,
                          onProviderSelected: (String userId) {
                            setState(() => _selectedProviderId = userId);
                            // Refresh feed in background so cards are up to date.
                            context.read<AppProvider>().loadPosts();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Row(
                                  children: [
                                    Icon(Icons.check_circle, color: Colors.white, size: 18),
                                    SizedBox(width: 10),
                                    Flexible(
                                        child: Text(
                                            'Provider selected. Tap "Secure Service" to pay.')),
                                  ],
                                ),
                                backgroundColor: AppTheme.successGreen,
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            );
                          },
                          onChatWithApplicant: (applicantUserId, applicantName,
                              applicantAvatarUrl) async {
                            await openChatWithUser(
                              context,
                              post.id,
                              applicantUserId,
                              otherUserName: applicantName,
                              otherUserAvatar: applicantAvatarUrl,
                              postTitle: post.title,
                            );
                          },
                        ),
                      ],
                      if (post.type == PostType.request &&
                          _selectedProviderId != null &&
                          _jobStatus != null) ...[
                        const SizedBox(height: 20),
                        _JobStatusCard(
                          status: _jobStatus!,
                          isDark: isDark,
                          isAuthor: isAuthor,
                          postStatus: post.status,
                        ),
                      ],
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: _buildActionBar(
            context,
            isDark: isDark,
            isAuthor: isAuthor,
            isOffline: isOffline,
            currentUserId: currentUserId,
            showPayButton: showPayButton,
            isSelectedProvider: isSelectedProvider,
          ),
        );
      },
    );
  }

  // ── App bar / media header ─────────────────────────────────────────────────

  Widget _buildAppBar(BuildContext context, bool isDark, bool isAuthor) {
    final surface = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final hasImages = post.images.isNotEmpty;
    return SliverAppBar(
      pinned: true,
      elevation: 0,
      expandedHeight: hasImages ? 300 : null,
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      leading: _CircleIconButton(
        icon: Icons.arrow_back_rounded,
        isDark: isDark,
        onScrim: hasImages,
        onTap: () => Navigator.pop(context),
      ),
      actions: [
        if (!isAuthor)
          ListenableBuilder(
            listenable: SavedService.instance,
            builder: (context, _) {
              final saved = SavedService.instance.isPostSaved(post.id);
              return _CircleIconButton(
                icon: saved
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                isDark: isDark,
                onScrim: hasImages,
                color: saved ? AppTheme.primaryAccent : null,
                onTap: () {
                  AuthGuard.requireAuth(
                    context,
                    action: 'save this post',
                    onAuthenticated: () {
                      final uid =
                          context.read<AuthProvider>().currentUserId ?? '';
                      SavedService.instance.togglePost(uid, post.id);
                    },
                  );
                },
              );
            },
          ),
        if (isAuthor)
          _CircleIconButton(
            icon: Icons.delete_outline_rounded,
            isDark: isDark,
            onScrim: hasImages,
            color: AppTheme.errorRed,
            onTap: () async {
              final deleted = await confirmAndDeletePost(context, post);
              if (deleted && context.mounted) Navigator.pop(context);
            },
          ),
        const SizedBox(width: 8),
      ],
      flexibleSpace: hasImages
          ? FlexibleSpaceBar(
              collapseMode: CollapseMode.parallax,
              background: _ImageCarousel(images: post.images),
            )
          : null,
    );
  }

  // ── Identity row: big type badge + urgency + posted time ──────────────────

  Widget _buildIdentityRow(bool isDark) {
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return Row(
      children: [
        _TypeBadge(label: post.typeDisplayLabel, color: post.typeBadgeColor),
        const SizedBox(width: 8),
        if (post.type == PostType.request)
          _MetaChip(
            label: post.urgencyText,
            color: post.urgencyColor,
            dot: true,
          ),
        const Spacer(),
        Text(
          formatRelativeTime(post.createdAt),
          style: TextStyle(color: tertiary, fontSize: 12.5),
        ),
      ],
    );
  }

  Widget _buildCategoryRow(bool isDark) {
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Row(
      children: [
        Icon(post.category.icon, size: 16, color: AppTheme.primaryAccent),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            post.category.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: secondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  // ── Structured details ────────────────────────────────────────────────────

  List<Widget> _buildDetailsSection(bool isDark) {
    final rows = <(IconData, String, String)>[
      (Icons.location_on_outlined, 'Location', post.location),
      if (post.type == PostType.job && post.employmentType != null)
        (Icons.work_outline_rounded, 'Employment', post.employmentType!.displayLabel),
      for (final row in attributeDetailRows(
        schema: CategorySchemaService.instance.schemaFor(post.category.name),
        postType: post.type.name,
        attributes: post.attributes,
      ))
        (Icons.check_circle_outline_rounded, row.label, row.value),
    ];
    if (rows.isEmpty) return const [];
    return [
      const SizedBox(height: 24),
      const _SectionHeader(title: 'Details'),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
        ),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  indent: 60,
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
              _DetailTile(
                icon: rows[i].$1,
                label: rows[i].$2,
                value: rows[i].$3,
                isDark: isDark,
              ),
            ],
          ],
        ),
      ),
    ];
  }

  // ── Sticky bottom action bar ──────────────────────────────────────────────

  Widget _buildActionBar(
    BuildContext context, {
    required bool isDark,
    required bool isAuthor,
    required bool isOffline,
    required String currentUserId,
    required bool showPayButton,
    required bool isSelectedProvider,
  }) {
    final surface = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    Widget content;
    if (isAuthor && showPayButton) {
      content = _SecureServiceButton(
        key: ValueKey('secure-$_paymentRefreshTick'),
        post: post,
        buyerUserId: currentUserId,
        providerUserId: _selectedProviderId,
        isOffline: isOffline,
        onTap: (normalizedPhone) {
          final fee = calculatePlatformFee(post.price);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PaymentScreen(
                postId: post.id,
                postTitle: post.title,
                amount: post.price,
                platformFee: fee,
                buyerUserId: currentUserId,
                buyerPhone: normalizedPhone,
              ),
            ),
          ).then((_) {
            // Re-check payment status + lifecycle when the user comes back.
            if (mounted) {
              setState(() => _paymentRefreshTick++);
              _refreshJobStatus();
            }
          });
        },
      );
    } else if (isAuthor && (_jobStatus?.isPendingApproval ?? false)) {
      content = SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton.icon(
          icon: const Icon(Icons.rate_review_rounded, size: 20),
          label: const Text('Review Completion'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.warningOrange,
            foregroundColor: Colors.white,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ApproveOrDisputeScreen(
                  postId: post.id,
                  postTitle: post.title,
                  clientUserId: currentUserId,
                  providerNote: _jobStatus?.providerNote,
                  amount: post.price,
                ),
              ),
            ).then((_) => _refreshJobStatus());
          },
        ),
      );
    } else if (isSelectedProvider && _jobStatus == null) {
      content = SizedBox(
        width: double.infinity,
        height: 52,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.task_alt_rounded, size: 20),
          label: const Text('Mark Job Done'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.successGreen,
            side: const BorderSide(color: AppTheme.successGreen),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => MarkCompleteScreen(
                  postId: post.id,
                  postTitle: post.title,
                  providerUserId: currentUserId,
                ),
              ),
            ).then((_) => _refreshJobStatus());
          },
        ),
      );
    } else if (!isAuthor &&
        _hasApplied &&
        post.type == PostType.request) {
      content = Container(
        width: double.infinity,
        height: 52,
        decoration: BoxDecoration(
          color: AppTheme.successGreen.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.successGreen.withValues(alpha: 0.45)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_rounded, color: AppTheme.successGreen, size: 20),
            SizedBox(width: 8),
            Text(
              'You already applied to this request',
              style: TextStyle(
                color: AppTheme.successGreen,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    } else if (!isAuthor &&
        post.type == PostType.request &&
        post.status != 'open') {
      content = Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.primaryAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          post.status == 'completed'
              ? 'This job is completed'
              : post.status == 'disputed'
                  ? 'This job is in dispute'
                  : 'This request already has a selected provider',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    } else if (!isAuthor) {
      // Full-width CTA. The price deliberately does NOT repeat here — it is
      // already prominent in the price card above; echoing it in the bar
      // squeezed the CTA label into truncation on narrow screens. (The owner's
      // "Secure Service · KES total" keeps its number because that is the
      // actual charge incl. platform fee, not an echo.)
      content = SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton.icon(
          onPressed: () {
            AuthGuard.requireAuth(
              context,
              action: post.type == PostType.request
                  ? 'offer service on this request'
                  : 'request this service',
              onAuthenticated: () => post.type == PostType.request
                  ? openOfferServiceModal(context, post)
                  : openPrivateChat(context, post),
            );
          },
          style: ElevatedButton.styleFrom(
            elevation: 0,
            textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          icon: Icon(
            switch (post.type) {
              PostType.offer => Icons.handshake_outlined,
              PostType.job => Iconsax.message,
              PostType.request => Iconsax.send_2,
            },
            size: 20,
          ),
          label: Text(
            switch (post.type) {
              PostType.offer => 'Request Service',
              PostType.job => 'Contact Poster',
              PostType.request => 'Offer Service',
            },
            maxLines: 1,
            overflow: TextOverflow.visible,
            softWrap: false,
          ),
        ),
      );
    } else if (post.type == PostType.request) {
      // Author of a request with no selection yet. One full-size element —
      // the applicant count folds into the button label (the Applicants
      // section above already shows the detail; a side-by-side text + small
      // button squeezed both).
      final count = post.applications.length;
      content = count == 0
          ? Container(
              height: 52,
              alignment: Alignment.center,
              child: Text(
                'No offers yet — providers will apply here',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                ),
              ),
            )
          : SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.tonalIcon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ApplicationsScreen(
                        postId: post.id,
                        postTitle: post.title,
                        authorUserId: currentUserId,
                      ),
                    ),
                  );
                },
                style: FilledButton.styleFrom(
                  textStyle: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w700),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: const Icon(Icons.people_alt_outlined, size: 20),
                label: Text(
                  'Manage $count ${count == 1 ? 'Applicant' : 'Applicants'}',
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            );
    } else {
      // Author viewing their own offer / job post.
      content = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline_rounded,
              size: 16,
              color:
                  isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
          const SizedBox(width: 8),
          Text(
            'You posted this ${post.type == PostType.offer ? 'service' : 'job'}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color:
                  isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
            ),
          ),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: content,
        ),
      ),
    );
  }
}

// ─── Media header ─────────────────────────────────────────────────────────────

class _ImageCarousel extends StatefulWidget {
  final List<String> images;

  const _ImageCarousel({required this.images});

  @override
  State<_ImageCarousel> createState() => _ImageCarouselState();
}

class _ImageCarouselState extends State<_ImageCarousel> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        PageView.builder(
          itemCount: widget.images.length,
          onPageChanged: (i) => setState(() => _page = i),
          itemBuilder: (context, index) => GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => _FullScreenGallery(
                  images: widget.images,
                  initialIndex: index,
                ),
              ),
            ),
            child: CachedNetworkImage(
              imageUrl: widget.images[index],
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(
                color: AppTheme.darkCard,
                child: const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              errorWidget: (_, __, ___) => Container(
                color: AppTheme.darkCard,
                child: const Icon(Icons.image_not_supported_outlined,
                    color: AppTheme.darkTextTertiary),
              ),
            ),
          ),
        ),
        // Bottom scrim so the page indicator reads on any photo.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 64,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black.withValues(alpha: 0.35)],
                ),
              ),
            ),
          ),
        ),
        if (widget.images.length > 1) ...[
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.images.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            right: 12,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${_page + 1}/${widget.images.length}',
                style: const TextStyle(
                    color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Full-screen swipeable, zoomable gallery.
class _FullScreenGallery extends StatefulWidget {
  final List<String> images;
  final int initialIndex;

  const _FullScreenGallery({required this.images, required this.initialIndex});

  @override
  State<_FullScreenGallery> createState() => _FullScreenGalleryState();
}

class _FullScreenGalleryState extends State<_FullScreenGallery> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _page = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.images.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, index) => InteractiveViewer(
              maxScale: 4,
              child: Center(
                child: CachedNetworkImage(
                  imageUrl: widget.images[index],
                  fit: BoxFit.contain,
                  placeholder: (_, __) => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  errorWidget: (_, __, ___) => const Icon(
                      Icons.image_not_supported_outlined,
                      color: Colors.white54),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.4),
                    ),
                  ),
                  if (widget.images.length > 1)
                    Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_page + 1} / ${widget.images.length}',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Small building blocks ────────────────────────────────────────────────────

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final bool isDark;
  final bool onScrim;
  final Color? color;
  final VoidCallback onTap;

  const _CircleIconButton({
    required this.icon,
    required this.isDark,
    required this.onScrim,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fg = color ??
        (onScrim
            ? Colors.white
            : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary));
    final bg = onScrim
        ? Colors.black.withValues(alpha: 0.35)
        : (isDark ? AppTheme.darkCard : AppTheme.lightBackground)
            .withValues(alpha: 0.9);
    return Center(
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 20, color: fg),
          ),
        ),
      ),
    );
  }
}

/// The large post-type identity badge (REQUEST / OFFER / JOB).
class _TypeBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _TypeBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool dot;

  const _MetaChip({required this.label, required this.color, this.dot = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

/// Price block — the money question answered up front, in the intent's own
/// language (Budget / Starting price / Salary).
class _PriceCard extends StatelessWidget {
  final PostModel post;
  final bool isDark;

  const _PriceCard({required this.post, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.successGreen.withValues(alpha: isDark ? 0.08 : 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.successGreen.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detailMoneyLabel(post.type),
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500, color: secondary),
                ),
                const SizedBox(height: 3),
                Text(
                  detailMoneyValue(
                    type: post.type,
                    price: post.price,
                    pricingType: post.pricingType,
                  ),
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.successGreen,
                  ),
                ),
              ],
            ),
          ),
          if (post.type == PostType.offer && post.authorHasPhone)
            _MetaChip(label: 'Accepts M-Pesa', color: AppTheme.successGreen),
        ],
      ),
    );
  }
}

/// Who is behind this post — avatar, name, live reputation.
class _AuthorCard extends StatelessWidget {
  final PostModel post;
  final bool isDark;
  final Widget? trailing;

  const _AuthorCard({required this.post, required this.isDark, this.trailing});

  @override
  Widget build(BuildContext context) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final tertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    final roleLabel = switch (post.type) {
      PostType.offer => 'Service provider',
      PostType.job => 'Hiring',
      PostType.request => 'Posted by',
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppTheme.primaryAccent.withValues(alpha: 0.15),
            backgroundImage:
                post.authorAvatar.isNotEmpty ? NetworkImage(post.authorAvatar) : null,
            child: post.authorAvatar.isEmpty
                ? Text(
                    post.authorName.isNotEmpty
                        ? post.authorName[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: AppTheme.primaryAccent,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  roleLabel,
                  style: TextStyle(fontSize: 11.5, color: tertiary),
                ),
                const SizedBox(height: 2),
                Text(
                  post.authorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                // Backend-sourced provider trust (no fake rating).
                ReputationCompact(providerId: post.authorUserId),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Collapsible description — expands past 6 lines only when the text needs it.
class _ExpandableText extends StatefulWidget {
  final String text;
  final bool isDark;

  const _ExpandableText({required this.text, required this.isDark});

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  static const _collapsedLines = 6;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 14.5,
      height: 1.55,
      color: widget.isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: _collapsedLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : _collapsedLines,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            if (overflows)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Text(
                    _expanded ? 'Show less' : 'Read more',
                    style: const TextStyle(
                      color: AppTheme.primaryAccent,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _DetailTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isDark;

  const _DetailTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppTheme.primaryAccent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 17, color: AppTheme.primaryAccent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: secondary),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Trust explainer for paid requests — outcome language, not financial jargon.
class _PaymentProtectionCard extends StatelessWidget {
  final bool isDark;

  const _PaymentProtectionCard({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.successGreen.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.successGreen.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.verified_user_rounded,
              color: AppTheme.successGreen, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Payment Protected',
                  style: TextStyle(
                    color: AppTheme.successGreen,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Pay through Help24 with M-Pesa and your money is held '
                  'safely until you approve the completed work. The provider '
                  'is paid only after your approval.',
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: secondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Applicants (request owner) — moved unchanged from the old sheet ─────────

class _ApplicantsSection extends StatefulWidget {
  final PostModel post;
  final bool isDark;
  final String? overrideSelectedId;
  final Function(String userId) onProviderSelected;
  final Future<void> Function(String applicantUserId, String applicantName,
      String applicantAvatarUrl) onChatWithApplicant;

  const _ApplicantsSection({
    required this.post,
    required this.isDark,
    required this.onProviderSelected,
    required this.onChatWithApplicant,
    this.overrideSelectedId,
  });

  @override
  State<_ApplicantsSection> createState() => _ApplicantsSectionState();
}

class _ApplicantsSectionState extends State<_ApplicantsSection> {
  String? _selecting;
  bool _chatLoading = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    // Card colours now live inside ApplicantCard — this section only lays out
    // the header and the list.
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    // Use override (post-selection local state) if available; fallback to DB value.
    final effectiveSelectedId =
        widget.overrideSelectedId ?? widget.post.selectedProviderUserId;
    final anySelected = effectiveSelectedId != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Row(
          children: [
            const _SectionHeader(title: 'Applicants'),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${widget.post.applications.length}',
                style: const TextStyle(
                  color: AppTheme.primaryAccent,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            const Spacer(),
            // Navigate to dedicated Applications management screen.
            TextButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ApplicationsScreen(
                      postId: widget.post.id,
                      postTitle: widget.post.title,
                      authorUserId: context.read<AuthProvider>().currentUserId ?? '',
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.open_in_full_rounded, size: 13),
              label: const Text('Manage'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Empty state
        if (widget.post.applications.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No offers yet. Check back later.',
              style: TextStyle(color: textSecondary, fontSize: 13),
            ),
          )
        else
          // The SAME card the Applications screen renders. These two lists are
          // the same decision on two surfaces; keeping one widget is what stops
          // them drifting apart again (this one used to show no trust signals
          // at all — just a name and a timestamp).
          ...widget.post.applications.map((app) {
            final isSelected = app.applicantUserId == effectiveSelectedId;
            final isSelecting = _selecting == app.applicantUserId;
            final canSelect =
                !anySelected && !isSelecting && app.applicantUserId.isNotEmpty;

            return ApplicantCard(
              application: app,
              isSelected: isSelected,
              isAccepting: isSelecting,
              canAccept: canSelect,
              onMessage: () async {
                if (_chatLoading) return;
                setState(() => _chatLoading = true);
                try {
                  await widget.onChatWithApplicant(app.applicantUserId,
                      app.applicantName, app.applicantAvatarUrl);
                } finally {
                  if (mounted) setState(() => _chatLoading = false);
                }
              },
              onAccept: () async {
                final clientUserId =
                    context.read<AuthProvider>().currentUserId ?? '';
                if (clientUserId.isEmpty) return;
                // Captured before the await so the failure path never reaches
                // for a BuildContext across an async gap.
                final messenger = ScaffoldMessenger.of(context);
                setState(() => _selecting = app.applicantUserId);
                try {
                  await JobsService.selectProvider(
                    postId: widget.post.id,
                    providerId: app.applicantUserId,
                    clientUserId: clientUserId,
                  );
                  if (mounted) {
                    setState(() => _selecting = null);
                    widget.onProviderSelected(app.applicantUserId);
                  }
                } catch (e) {
                  debugPrint('[SelectProvider] UI caught error: $e');
                  if (mounted) {
                    setState(() => _selecting = null);
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(ErrorMapper.toMessage(e,
                            context: ErrorContext.selectProvider)),
                        backgroundColor: AppTheme.errorRed,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                  }
                }
              },
            );
          }),
      ],
    );
  }
}

// ─── Job lifecycle status — moved unchanged from the old sheet ───────────────

class _JobStatusCard extends StatelessWidget {
  final JobCompletionStatus status;
  final bool isDark;
  // Role-aware wording: the CLIENT reviews/approves; the PROVIDER waits on them.
  final bool isAuthor;
  // Canonical post status — lets a resolved dispute (post 'completed') override a
  // stale job_completions='disputed' so this card agrees with the discover card.
  final String postStatus;

  const _JobStatusCard({
    required this.status,
    required this.isDark,
    required this.isAuthor,
    required this.postStatus,
  });

  @override
  Widget build(BuildContext context) {
    final bool resolved = postStatus == 'completed';
    final (label, icon, bg, fg) = switch (status.status) {
      'pending_approval' => (
          isAuthor ? 'Awaiting your review' : 'Awaiting client review',
          Icons.hourglass_top_rounded,
          AppTheme.warningOrange.withValues(alpha: 0.12),
          AppTheme.warningOrange,
        ),
      'approved' => (
          'Job completed — payment released',
          Icons.check_circle_rounded,
          AppTheme.successGreen.withValues(alpha: 0.12),
          AppTheme.successGreen,
        ),
      // A resolved dispute leaves the post 'completed'; don't keep showing
      // "admin reviewing" once the case is closed.
      'disputed' => resolved
          ? (
              'Dispute resolved — job completed',
              Icons.check_circle_rounded,
              AppTheme.successGreen.withValues(alpha: 0.12),
              AppTheme.successGreen,
            )
          : (
              'Dispute opened — admin reviewing',
              Icons.gavel_rounded,
              AppTheme.errorRed.withValues(alpha: 0.10),
              AppTheme.errorRed,
            ),
      _ => (
          'In progress',
          Icons.construction_rounded,
          AppTheme.primaryAccent.withValues(alpha: 0.10),
          AppTheme.primaryAccent,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: fg.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Secure Service button — moved unchanged from the old sheet ──────────────

enum _SecureButtonState { loading, ready, paid }

class _SecureServiceButton extends StatefulWidget {
  final PostModel post;
  final String buyerUserId;

  /// Effective selected-provider ID (may be a local override not yet synced to
  /// post.selectedProviderUserId).
  final String? providerUserId;
  final bool isOffline;

  /// Called with the normalized 254XXXXXXXXX phone after preflight checks pass.
  final void Function(String normalizedPhone) onTap;

  const _SecureServiceButton({
    super.key,
    required this.post,
    required this.buyerUserId,
    required this.isOffline,
    required this.onTap,
    this.providerUserId,
  });

  @override
  State<_SecureServiceButton> createState() => _SecureServiceButtonState();
}

class _SecureServiceButtonState extends State<_SecureServiceButton> {
  _SecureButtonState _btnState = _SecureButtonState.loading;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _checkPaymentStatus();
  }

  // A transaction in any post-payment state means the service is already secured;
  // "Secure Service" must never reappear once payment has been made (Issue 5).
  static const _securedStatuses = {'paid', 'payout_pending', 'released', 'disputed', 'refunded'};

  Future<void> _checkPaymentStatus() async {
    try {
      final status = await MpesaService.pollPaymentStatus(widget.post.id);
      if (!mounted) return;
      final secured = _securedStatuses.contains(status.status);
      setState(() =>
          _btnState = secured ? _SecureButtonState.paid : _SecureButtonState.ready);
    } catch (_) {
      // 404 = no transaction yet — show the button.
      if (mounted) setState(() => _btnState = _SecureButtonState.ready);
    }
  }

  Future<void> _handleTap() async {
    if (widget.isOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(children: [
            Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Flexible(child: Text("You're offline. Connect to proceed.")),
          ]),
          backgroundColor: AppTheme.warningOrange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    if (widget.buyerUserId.isEmpty) return;

    setState(() => _checking = true);
    try {
      // ── Precheck 1: buyer M-Pesa phone ───────────────────────────────────
      String? rawPhone = await UserProfileService.getMpesaPhone(widget.buyerUserId);
      if (!mounted) return;

      // Fallback: for phone-auth users the Firebase phone number is the same
      // M-Pesa number — use it when the Supabase profile hasn't been explicitly set.
      if ((rawPhone == null || rawPhone.isEmpty)) {
        final fbPhone = context.read<AuthProvider>().currentUser?.phoneNumber;
        if (fbPhone != null && fbPhone.isNotEmpty) {
          debugPrint('[SecureBtn] DB phone missing — falling back to Firebase phone');
          rawPhone = fbPhone;
        }
      }

      debugPrint('[SecureBtn] buyer raw="$rawPhone"');
      final normalizedPhone = rawPhone != null ? normalizeKenyanNumber(rawPhone) : null;
      debugPrint('[SecureBtn] buyer normalized="$normalizedPhone"');

      if (normalizedPhone == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(children: [
              Icon(Icons.phone_android_rounded, color: Colors.white, size: 18),
              SizedBox(width: 10),
              Flexible(
                  child: Text(
                      'Add a valid M-Pesa number in Profile → Payment Settings.')),
            ]),
            backgroundColor: AppTheme.warningOrange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration: const Duration(seconds: 4),
          ),
        );
        return;
      }

      // ── Precheck 2: selected provider still has an M-Pesa number ─────────
      final providerUserId =
          widget.providerUserId ?? widget.post.selectedProviderUserId;
      if (providerUserId != null && providerUserId.isNotEmpty) {
        final providerRaw = await UserProfileService.getMpesaPhone(providerUserId);
        if (!mounted) return;
        if (providerRaw == null || providerRaw.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(children: [
                Icon(Icons.warning_amber_rounded, color: Colors.white, size: 18),
                SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'The selected provider has not added their M-Pesa number yet. '
                    'Ask them to add it before you can pay.',
                  ),
                ),
              ]),
              backgroundColor: AppTheme.warningOrange,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              duration: const Duration(seconds: 5),
            ),
          );
          return;
        }
      }

      // ── Precheck 3: post is not already paid ─────────────────────────────
      // (pollPaymentStatus was already checked in initState; re-verify on tap
      //  in case the user tapped "Secure Service" twice or state is stale.)
      if (_btnState == _SecureButtonState.paid) return;

      // All checks passed — proceed to payment.
      widget.onTap(normalizedPhone);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_btnState == _SecureButtonState.loading) {
      return const SizedBox(
        height: 52,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppTheme.successGreen),
          ),
        ),
      );
    }

    if (_btnState == _SecureButtonState.paid) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.successGreen.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.successGreen.withValues(alpha: 0.4)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_rounded, color: AppTheme.successGreen, size: 18),
            SizedBox(width: 8),
            Text(
              'Payment Secured',
              style: TextStyle(
                color: AppTheme.successGreen,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ],
        ),
      );
    }

    final total = formatPriceWithCommas(
        widget.post.price + calculatePlatformFee(widget.post.price));
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: widget.isOffline
              ? AppTheme.successGreen.withValues(alpha: 0.55)
              : AppTheme.successGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: _checking ? null : _handleTap,
        icon: _checking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Icon(widget.isOffline ? Icons.wifi_off_rounded : Icons.lock_rounded,
                size: 18),
        label: Text(
          widget.isOffline ? 'Secure Service (offline)' : 'Secure Service · KES $total',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
