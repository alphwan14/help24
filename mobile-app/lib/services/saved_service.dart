import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';
import 'post_service.dart';

/// A saved provider row for the shortlist (joined from public_profiles).
class SavedProvider {
  final String userId;
  final String name;
  final String avatarUrl;

  const SavedProvider({
    required this.userId,
    required this.name,
    required this.avatarUrl,
  });
}

/// Personal shortlist (Profile → Saved): posts (requests/offers/jobs) and
/// providers. Backed by the RLS-owner-scoped `saved_items` table (082).
///
/// Design notes:
/// - Singleton ChangeNotifier so bookmark toggles anywhere in the app update
///   every listening widget instantly (detail screen, saved screen).
/// - Optimistic writes: the icon flips immediately; on a failed write the
///   state reverts and listeners are re-notified.
/// - Degrades to empty/silent if the migration is not applied yet — saving
///   is an enhancement and must never break browsing.
class SavedService extends ChangeNotifier {
  SavedService._();

  static final SavedService instance = SavedService._();

  static SupabaseClient get _db => Supabase.instance.client;

  String _loadedForUserId = '';
  bool _loading = false;
  final Set<String> _postIds = {};
  final Set<String> _providerIds = {};

  bool isPostSaved(String postId) => _postIds.contains(postId);
  bool isProviderSaved(String providerId) => _providerIds.contains(providerId);
  int get savedCount => _postIds.length + _providerIds.length;

  /// Load (once per signed-in user) the ids of everything they saved, so
  /// bookmark icons render correct state. Cheap to call from build paths.
  Future<void> ensureLoaded(String userId) async {
    if (userId.isEmpty) {
      if (_loadedForUserId.isNotEmpty) {
        _loadedForUserId = '';
        _postIds.clear();
        _providerIds.clear();
        notifyListeners();
      }
      return;
    }
    if (_loading || _loadedForUserId == userId) return;
    _loading = true;
    try {
      final rows = await _db
          .from('saved_items')
          .select('item_type, item_id')
          .eq('user_id', userId);
      _postIds.clear();
      _providerIds.clear();
      for (final row in rows as List) {
        final type = row['item_type'] as String?;
        final id = row['item_id'] as String? ?? '';
        if (id.isEmpty) continue;
        if (type == 'post') _postIds.add(id);
        if (type == 'provider') _providerIds.add(id);
      }
      _loadedForUserId = userId;
      notifyListeners();
    } catch (e) {
      // Table missing (082 not applied) or offline — behave as "nothing saved".
      debugPrint('[SAVED] ensureLoaded skipped: $e');
    } finally {
      _loading = false;
    }
  }

  Future<void> togglePost(String userId, String postId) =>
      _toggle(userId, 'post', postId, _postIds);

  Future<void> toggleProvider(String userId, String providerId) =>
      _toggle(userId, 'provider', providerId, _providerIds);

  Future<void> _toggle(
      String userId, String itemType, String itemId, Set<String> ids) async {
    if (userId.isEmpty || itemId.isEmpty) return;
    final wasSaved = ids.contains(itemId);
    // Optimistic flip.
    if (wasSaved) {
      ids.remove(itemId);
    } else {
      ids.add(itemId);
    }
    notifyListeners();
    try {
      if (wasSaved) {
        await _db.from('saved_items').delete().match({
          'user_id': userId,
          'item_type': itemType,
          'item_id': itemId,
        });
      } else {
        // Upsert: double-taps and races never violate the UNIQUE constraint.
        await _db.from('saved_items').upsert(
          {'user_id': userId, 'item_type': itemType, 'item_id': itemId},
          onConflict: 'user_id,item_type,item_id',
          ignoreDuplicates: true,
        );
      }
    } catch (e) {
      debugPrint('[SAVED] toggle $itemType/$itemId failed: $e');
      // Revert the optimistic flip.
      if (wasSaved) {
        ids.add(itemId);
      } else {
        ids.remove(itemId);
      }
      notifyListeners();
    }
  }

  /// Saved posts, newest-saved first. Archived/deleted posts drop out
  /// naturally (fetch is by id against the live feed query shape).
  Future<List<PostModel>> fetchSavedPosts(String userId) async {
    if (userId.isEmpty) return const [];
    final rows = await _db
        .from('saved_items')
        .select('item_id')
        .eq('user_id', userId)
        .eq('item_type', 'post')
        .order('created_at', ascending: false);
    final ids = [
      for (final row in rows as List)
        if ((row['item_id'] as String? ?? '').isNotEmpty) row['item_id'] as String
    ];
    if (ids.isEmpty) return const [];
    final posts = await PostService.fetchPostsByIds(ids);
    // Preserve saved order (fetch returns feed order).
    final byId = {for (final p in posts) p.id: p};
    return [
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!
    ];
  }

  /// Saved providers, newest-saved first (safe author fields only).
  Future<List<SavedProvider>> fetchSavedProviders(String userId) async {
    if (userId.isEmpty) return const [];
    final rows = await _db
        .from('saved_items')
        .select('item_id')
        .eq('user_id', userId)
        .eq('item_type', 'provider')
        .order('created_at', ascending: false);
    final ids = [
      for (final row in rows as List)
        if ((row['item_id'] as String? ?? '').isNotEmpty) row['item_id'] as String
    ];
    if (ids.isEmpty) return const [];
    final profiles = await _db
        .from('public_profiles')
        .select('id, name, avatar_url')
        .inFilter('id', ids);
    final byId = <String, SavedProvider>{};
    for (final row in profiles as List) {
      final id = row['id'] as String? ?? '';
      if (id.isEmpty) continue;
      byId[id] = SavedProvider(
        userId: id,
        name: (row['name'] as String?)?.trim().isNotEmpty == true
            ? (row['name'] as String).trim()
            : 'Provider',
        avatarUrl: row['avatar_url'] as String? ?? '',
      );
    }
    return [
      for (final id in ids)
        if (byId.containsKey(id)) byId[id]!
    ];
  }
}
