import 'dart:math';
import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:provider/provider.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../services/post_service.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';
import '../widgets/auth_guard.dart';
import 'messages_screen.dart';

class UrgentRequestsScreen extends StatefulWidget {
  const UrgentRequestsScreen({super.key});

  @override
  State<UrgentRequestsScreen> createState() => _UrgentRequestsScreenState();
}

class _UrgentRequestsScreenState extends State<UrgentRequestsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final location = context.read<LocationProvider>();
      context.read<AppProvider>().loadUrgentPosts(
            userLatitude: location.latitude,
            userLongitude: location.longitude,
            limit: 20,
          );
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final location = context.watch<LocationProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Urgent Requests')),
      body: Consumer<AppProvider>(
        builder: (context, provider, _) {
          final posts = provider.urgentPosts;
          if (provider.isLoadingUrgentPosts && posts.isEmpty) {
            return const Center(child: CircularProgressIndicator(strokeWidth: 2));
          }
          if (posts.isEmpty) {
            return const Center(child: Text('No urgent requests nearby'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: posts.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final post = posts[index];
              final distance = _distanceText(post, location.latitude, location.longitude);
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _showPostQuickView(context, post, distance),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.errorRed.withValues(alpha: 0.45)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: AppTheme.errorRed.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'URGENT',
                          style: TextStyle(
                            color: AppTheme.errorRed,
                            fontWeight: FontWeight.w700,
                            fontSize: 10.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        post.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(Icons.location_on_outlined, size: 14, color: AppTheme.primaryAccent),
                          const SizedBox(width: 4),
                          Text(distance ?? 'Nearby', style: Theme.of(context).textTheme.bodySmall),
                          const SizedBox(width: 10),
                          const Icon(Iconsax.clock, size: 14, color: AppTheme.primaryAccent),
                          const SizedBox(width: 4),
                          Text(formatRelativeTime(post.createdAt), style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showPostQuickView(BuildContext context, PostModel post, String? distanceText) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.8),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(post.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(post.description, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 12),
              Text(
                '${distanceText ?? 'Nearby'} • ${formatRelativeTime(post.createdAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    AuthGuard.requireAuth(
                      context,
                      action: 'offer help on this urgent request',
                      onAuthenticated: () => _openPrivateChat(context, post),
                    );
                  },
                  icon: const Text('⚡'),
                  label: const Text('Offer Help Now'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openPrivateChat(BuildContext context, PostModel post) async {
    final appProvider = context.read<AppProvider>();
    final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
    if (currentUserId.isEmpty) return;
    String authorId = post.authorUserId;
    if (authorId.isEmpty) {
      try {
        final freshPost = await PostService.getPostById(post.id);
        authorId = freshPost?.authorUserId ?? '';
      } catch (_) {
        authorId = '';
      }
    }
    if (authorId.isEmpty || authorId == currentUserId) return;
    final conv = await appProvider.ensureConversationOnApply(
      applicantId: currentUserId,
      authorId: authorId,
      initialMessage: '',
      postId: post.id,
    );
    if (!context.mounted || conv == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (c) => ChatScreen(conversation: conv, currentUserId: currentUserId),
      ),
    );
  }

  String? _distanceText(PostModel post, double? userLat, double? userLng) {
    if (post.latitude == null || post.longitude == null || userLat == null || userLng == null) {
      return null;
    }
    final km = _distanceKm(userLat, userLng, post.latitude!, post.longitude!);
    if (km < 1) return '${(km * 1000).round()} m away';
    return '${km.toStringAsFixed(1)} km away';
  }

  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = (sin(dLat / 2) * sin(dLat / 2)) +
        cos(_degToRad(lat1)) * cos(_degToRad(lat2)) * (sin(dLon / 2) * sin(dLon / 2));
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return r * c;
  }

  double _degToRad(double deg) => deg * (pi / 180.0);
}
