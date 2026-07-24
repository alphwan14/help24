import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import '../models/attribute_display.dart';
import '../models/post_model.dart';
import '../services/saved_service.dart';
import '../theme/app_theme.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/post_flows.dart';
import '../widgets/reputation_widgets.dart';
import 'post_detail_screen.dart';

enum _SavedFilter { all, requests, offers, jobs, providers }

/// Profile → Saved: the user's personal shortlist of posts and providers.
/// Deliberately NOT a feed — compact rows, saved order, one-tap unsave.
class SavedScreen extends StatefulWidget {
  final String userId;

  const SavedScreen({super.key, required this.userId});

  @override
  State<SavedScreen> createState() => _SavedScreenState();
}

class _SavedScreenState extends State<SavedScreen> {
  _SavedFilter _filter = _SavedFilter.all;
  List<PostModel> _posts = const [];
  List<SavedProvider> _providers = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    // Unsaves from anywhere (e.g. a detail screen pushed from here) reflect
    // back into this list when we return.
    SavedService.instance.addListener(_onSavedChanged);
  }

  @override
  void dispose() {
    SavedService.instance.removeListener(_onSavedChanged);
    super.dispose();
  }

  void _onSavedChanged() {
    if (!mounted) return;
    setState(() {
      _posts = _posts
          .where((p) => SavedService.instance.isPostSaved(p.id))
          .toList();
      _providers = _providers
          .where((p) => SavedService.instance.isProviderSaved(p.userId))
          .toList();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await SavedService.instance.ensureLoaded(widget.userId);
      final results = await Future.wait([
        SavedService.instance.fetchSavedPosts(widget.userId),
        SavedService.instance.fetchSavedProviders(widget.userId),
      ]);
      if (!mounted) return;
      setState(() {
        _posts = results[0] as List<PostModel>;
        _providers = results[1] as List<SavedProvider>;
      });
    } catch (e) {
      debugPrint('[SAVED] load failed: $e');
      if (mounted) setState(() => _error = 'Could not load your saved items.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<PostModel> get _filteredPosts => switch (_filter) {
        _SavedFilter.all => _posts,
        _SavedFilter.requests =>
          _posts.where((p) => p.type == PostType.request).toList(),
        _SavedFilter.offers =>
          _posts.where((p) => p.type == PostType.offer).toList(),
        _SavedFilter.jobs => _posts.where((p) => p.type == PostType.job).toList(),
        _SavedFilter.providers => const [],
      };

  bool get _showProviders =>
      _filter == _SavedFilter.all || _filter == _SavedFilter.providers;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: textPrimary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Saved',
          style: TextStyle(
              color: textPrimary, fontWeight: FontWeight.w700, fontSize: 18),
        ),
      ),
      body: ReconnectListener(
        onReconnect: _load,
        child: Column(
          children: [
            _buildFilterChips(isDark),
            const SizedBox(height: 4),
            Expanded(child: _buildBody(isDark)),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChips(bool isDark) {
    const labels = {
      _SavedFilter.all: 'All',
      _SavedFilter.requests: 'Requests',
      _SavedFilter.offers: 'Offers',
      _SavedFilter.jobs: 'Jobs',
      _SavedFilter.providers: 'Providers',
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Row(
        children: [
          for (final f in _SavedFilter.values) ...[
            ChoiceChip(
              label: Text(labels[f]!),
              selected: _filter == f,
              onSelected: (_) => setState(() => _filter = f),
              labelStyle: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _filter == f
                    ? AppTheme.primaryAccent
                    : (isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline_rounded, color: secondary, size: 40),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: secondary, fontSize: 14)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _load,
              child: const Text('Retry',
                  style: TextStyle(color: AppTheme.primaryAccent)),
            ),
          ],
        ),
      );
    }

    final posts = _filteredPosts;
    final providers = _showProviders ? _providers : const <SavedProvider>[];

    if (posts.isEmpty && providers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Iconsax.archive_1, color: secondary, size: 44),
              const SizedBox(height: 14),
              Text(
                'Nothing saved yet',
                style: TextStyle(
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Tap the bookmark on any post — or save a provider from their service page — to build your shortlist.',
                textAlign: TextAlign.center,
                style: TextStyle(color: secondary, fontSize: 13, height: 1.45),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primaryAccent,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          for (final post in posts) ...[
            _SavedPostRow(
              post: post,
              isDark: isDark,
              userId: widget.userId,
              onOpen: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => PostDetailScreen(post: post)),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (providers.isNotEmpty) ...[
            if (posts.isNotEmpty && _filter == _SavedFilter.all) ...[
              const SizedBox(height: 8),
              Text(
                'Providers',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
            ],
            for (final provider in providers) ...[
              _SavedProviderRow(
                provider: provider,
                isDark: isDark,
                userId: widget.userId,
              ),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ),
    );
  }
}

class _SavedPostRow extends StatelessWidget {
  final PostModel post;
  final bool isDark;
  final String userId;
  final VoidCallback onOpen;

  const _SavedPostRow({
    required this.post,
    required this.isDark,
    required this.userId,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final money = cardMoneyLabel(
      type: post.type,
      price: post.price,
      pricingType: post.pricingType,
    );

    return Material(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ),
          child: Row(
            children: [
              // Thumbnail: first image, else category icon tile.
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: post.images.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: post.images.first,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) =>
                              _iconTile(post.category.icon),
                        )
                      : _iconTile(post.category.icon),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: post.typeBadgeColor.withValues(alpha: 0.13),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            post.typeDisplayLabel,
                            style: TextStyle(
                              color: post.typeBadgeColor,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (money != null) ...[
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              money,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: secondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Remove from saved',
                icon: const Icon(Icons.bookmark_rounded,
                    color: AppTheme.primaryAccent, size: 22),
                onPressed: () =>
                    SavedService.instance.togglePost(userId, post.id),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconTile(IconData icon) => Container(
        color: AppTheme.primaryAccent.withValues(alpha: 0.12),
        child: Icon(icon, color: AppTheme.primaryAccent, size: 22),
      );
}

class _SavedProviderRow extends StatelessWidget {
  final SavedProvider provider;
  final bool isDark;
  final String userId;

  const _SavedProviderRow({
    required this.provider,
    required this.isDark,
    required this.userId,
  });

  @override
  Widget build(BuildContext context) {
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppTheme.primaryAccent.withValues(alpha: 0.15),
            backgroundImage: provider.avatarUrl.isNotEmpty
                ? NetworkImage(provider.avatarUrl)
                : null,
            child: provider.avatarUrl.isEmpty
                ? Text(
                    provider.name.isNotEmpty
                        ? provider.name[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: AppTheme.primaryAccent,
                      fontWeight: FontWeight.w700,
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
                  provider.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                ReputationCompact(providerId: provider.userId),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Message',
            icon: const Icon(Iconsax.message,
                color: AppTheme.primaryAccent, size: 20),
            onPressed: () => openChatWithUser(
              context,
              '',
              provider.userId,
              otherUserName: provider.name,
              otherUserAvatar: provider.avatarUrl,
            ),
          ),
          IconButton(
            tooltip: 'Remove from saved',
            icon: const Icon(Icons.bookmark_rounded,
                color: AppTheme.primaryAccent, size: 22),
            onPressed: () =>
                SavedService.instance.toggleProvider(userId, provider.userId),
          ),
        ],
      ),
    );
  }
}
