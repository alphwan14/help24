import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/post_model.dart' show Conversation;
import '../models/provider_reputation.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../services/reputation_service.dart';
import '../services/saved_service.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';
import '../widgets/auth_guard.dart';
import '../widgets/profile_widgets.dart';
import '../widgets/reputation_widgets.dart';
import 'messages_screen.dart';

/// The public provider profile — the destination "View Profile" never had.
///
/// Read-only by construction: it renders another person's professional
/// identity (profession, bio, member since) alongside their server-derived
/// trust record (tier, rating, jobs, completion rate) and their reviews. There
/// is no edit path here and no write of any kind.
///
/// Honest-by-default: every number comes from ReputationService (backed by the
/// service-role-only `provider_reputation` table). A provider with no history
/// reads "New on Help24", never a zero-filled report card.
class ProviderProfileScreen extends StatefulWidget {
  final String providerId;

  /// Optional seeds from the surface that opened this screen (an applicant
  /// card already knows the name/avatar/profession), so the header paints
  /// instantly instead of flashing a spinner.
  final String? initialName;
  final String? initialAvatarUrl;
  final String? initialProfession;

  const ProviderProfileScreen({
    super.key,
    required this.providerId,
    this.initialName,
    this.initialAvatarUrl,
    this.initialProfession,
  });

  @override
  State<ProviderProfileScreen> createState() => _ProviderProfileScreenState();
}

class _ProviderProfileScreenState extends State<ProviderProfileScreen> {
  UserModel? _profile;
  ProviderReputation? _reputation;
  List<ProviderReview> _reviews = const [];
  String? _reviewsCursor;
  bool _loading = true;
  bool _loadingMoreReviews = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    final uid = context.read<AuthProvider>().currentUserId;
    if (uid != null && uid.isNotEmpty) {
      SavedService.instance.ensureLoaded(uid);
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => _error = null);
    try {
      final results = await Future.wait([
        UserProfileService.getPublicProfile(widget.providerId),
        ReputationService.getReputation(widget.providerId),
        ReputationService.getProviderReviews(widget.providerId, limit: 5),
      ]);
      if (!mounted) return;
      final page = results[2] as ProviderReviewsPage;
      setState(() {
        _profile = results[0] as UserModel?;
        _reputation = results[1] as ProviderReputation?;
        _reviews = page.reviews;
        _reviewsCursor = page.nextCursor;
        _loading = false;
        // Only a missing profile is a hard failure. Reputation and reviews
        // degrade to their own honest empty states.
        if (_profile == null) _error = "We couldn't load this profile.";
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "We couldn't load this profile.";
      });
    }
  }

  Future<void> _loadMoreReviews() async {
    final cursor = _reviewsCursor;
    if (cursor == null || _loadingMoreReviews) return;
    setState(() => _loadingMoreReviews = true);
    final page = await ReputationService.getProviderReviews(
      widget.providerId,
      limit: 10,
      cursor: cursor,
    );
    if (!mounted) return;
    setState(() {
      _reviews = [..._reviews, ...page.reviews];
      _reviewsCursor = page.nextCursor;
      _loadingMoreReviews = false;
    });
  }

  String get _name {
    final fromProfile = (_profile?.name ?? '').trim();
    if (fromProfile.isNotEmpty) return fromProfile;
    final seeded = (widget.initialName ?? '').trim();
    return seeded.isNotEmpty ? seeded : 'Provider';
  }

  String get _avatar {
    final fromProfile = (_profile?.profileImage ?? '').trim();
    return fromProfile.isNotEmpty ? fromProfile : (widget.initialAvatarUrl ?? '');
  }

  String get _profession {
    final fromProfile = (_profile?.profession ?? '').trim();
    return fromProfile.isNotEmpty ? fromProfile : (widget.initialProfession ?? '');
  }

  void _message() {
    final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
    if (currentUserId.isEmpty || widget.providerId.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          conversation: Conversation(
            id: '',
            participantId: widget.providerId,
            userName: _name,
            userAvatar: _avatar,
            lastMessage: '',
            lastMessageTime: DateTime.now(),
          ),
          currentUserId: currentUserId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelf = context.read<AuthProvider>().currentUserId == widget.providerId;

    return Scaffold(
      backgroundColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      appBar: AppBar(
        title: const Text('Profile'),
        centerTitle: true,
        actions: [
          if (!isSelf && widget.providerId.isNotEmpty)
            ListenableBuilder(
              listenable: SavedService.instance,
              builder: (context, _) {
                final saved = SavedService.instance.isProviderSaved(widget.providerId);
                return IconButton(
                  tooltip: saved ? 'Saved' : 'Save provider',
                  icon: Icon(
                    saved ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
                    color: saved ? AppTheme.primaryAccent : null,
                  ),
                  onPressed: () => AuthGuard.requireAuth(
                    context,
                    action: 'save this provider',
                    onAuthenticated: () {
                      final uid = context.read<AuthProvider>().currentUserId ?? '';
                      SavedService.instance.toggleProvider(uid, widget.providerId);
                    },
                  ),
                );
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.primaryAccent,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                    children: [
                      _Header(
                        name: _name,
                        avatarUrl: _avatar,
                        profession: _profession,
                        reputation: _reputation,
                        memberSince: _memberSince,
                      ),
                      const SizedBox(height: 20),

                      // Trust record — the same server-derived section used on
                      // the account tab, so the numbers can never disagree.
                      ReputationProfileSection(providerId: widget.providerId),

                      if ((_profile?.bio ?? '').trim().isNotEmpty) ...[
                        const SizedBox(height: 20),
                        _Section(
                          title: 'About',
                          child: Text(
                            _profile!.bio.trim(),
                            style: const TextStyle(fontSize: 14.5, height: 1.55),
                          ),
                        ),
                      ],

                      const SizedBox(height: 20),
                      _ReviewsSection(
                        reviews: _reviews,
                        totalReviews: _reputation?.totalReviews ?? 0,
                        hasMore: _reviewsCursor != null,
                        loadingMore: _loadingMoreReviews,
                        onLoadMore: _loadMoreReviews,
                      ),
                    ],
                  ),
                ),
      bottomNavigationBar: (isSelf || _loading || _error != null)
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: () => AuthGuard.requireAuth(
                    context,
                    action: 'message this provider',
                    onAuthenticated: _message,
                  ),
                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                  label: Text('Message $_name'.length > 28 ? 'Message' : 'Message $_name'),
                ),
              ),
            ),
    );
  }

  /// Prefer the reputation payload's member_since (it is the same
  /// `users.created_at`, and it is present even when the profile read is thin).
  String? get _memberSince {
    final iso = _reputation?.memberSince;
    final created = iso != null ? DateTime.tryParse(iso) : _profile?.createdAt;
    if (created == null) return null;
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final local = created.toLocal();
    return '${months[local.month - 1]} ${local.year}';
  }
}

class _Header extends StatelessWidget {
  final String name;
  final String avatarUrl;
  final String profession;
  final ProviderReputation? reputation;
  final String? memberSince;

  const _Header({
    required this.name,
    required this.avatarUrl,
    required this.profession,
    required this.reputation,
    required this.memberSince,
  });

  @override
  Widget build(BuildContext context) {
    final rep = reputation;
    return Column(
      children: [
        ProfileAvatar(
          imageUrl: avatarUrl,
          name: name,
          size: 96,
          showGradient: true,
        ),
        const SizedBox(height: 16),
        Text(
          name,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        // Profession is the primary trust indicator here (spec §5) — it sits
        // immediately under the name, above every other signal.
        if (profession.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          ProfessionChip(profession: profession, fontSize: 13),
        ],
        if (rep != null) ...[
          const SizedBox(height: 10),
          TierBadge(tier: rep.tier, label: rep.tierLabel, fontSize: 12),
        ],
        if (memberSince != null) ...[
          const SizedBox(height: 10),
          Text('Member since $memberSince',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _ReviewsSection extends StatelessWidget {
  final List<ProviderReview> reviews;
  final int totalReviews;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback onLoadMore;

  const _ReviewsSection({
    required this.reviews,
    required this.totalReviews,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    if (reviews.isEmpty) {
      return _Section(
        title: 'Reviews',
        child: Row(
          children: [
            Icon(Icons.rate_review_outlined,
                size: 18, color: Theme.of(context).textTheme.bodySmall?.color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'No reviews yet. Reviews appear after a completed job.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Text(
            totalReviews > 0 ? 'Reviews ($totalReviews)' : 'Reviews',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        for (final review in reviews) _ReviewTile(review: review),
        if (hasMore)
          Center(
            child: TextButton(
              onPressed: loadingMore ? null : onLoadMore,
              child: loadingMore
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Show more reviews'),
            ),
          ),
      ],
    );
  }
}

class _ReviewTile extends StatelessWidget {
  final ProviderReview review;

  const _ReviewTile({required this.review});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final created =
        review.createdAt != null ? DateTime.tryParse(review.createdAt!) : null;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 1; i <= 5; i++)
                Icon(
                  i <= review.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 16,
                  color: AppTheme.warningOrange,
                ),
              const Spacer(),
              if (created != null)
                Text(formatRelativeTime(created),
                    style: TextStyle(color: muted, fontSize: 11.5)),
            ],
          ),
          if ((review.comment ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(review.comment!.trim(),
                style: const TextStyle(fontSize: 13.5, height: 1.45)),
          ],
          if ((review.providerReply ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Response from provider',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryAccent)),
                  const SizedBox(height: 4),
                  Text(review.providerReply!.trim(),
                      style: const TextStyle(fontSize: 13, height: 1.4)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 44, color: AppTheme.errorRed.withValues(alpha: 0.7)),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
