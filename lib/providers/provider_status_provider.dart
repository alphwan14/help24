import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tracks whether the logged-in user is a provider.
/// A user is a provider if they have at least one active offer post.
/// Creating an offer automatically makes them a provider — no separate registration needed.
class ProviderStatusProvider extends ChangeNotifier {
  bool _isProvider = false;
  bool _isLoading = false;
  String? _lastFetchedUserId;

  bool get isProvider => _isProvider;
  bool get isLoading => _isLoading;

  /// Fetch provider status by checking for offer posts by [userId].
  /// Skips if the same user was already checked (unless [force] is true).
  Future<void> fetchStatus(String? userId, {bool force = false}) async {
    if (userId == null || userId.isEmpty) {
      _reset();
      return;
    }

    if (!force && userId == _lastFetchedUserId && !_isLoading) return;

    _isLoading = true;
    notifyListeners();

    try {
      final result = await Supabase.instance.client
          .from('posts')
          .select('id')
          .eq('author_user_id', userId)
          .eq('type', 'offer')
          .limit(1);

      _isProvider = (result as List).isNotEmpty;
      _lastFetchedUserId = userId;
      debugPrint('[ProviderStatus] userId=$userId isProvider=$_isProvider');
    } catch (e) {
      debugPrint('[ProviderStatus] Error: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Force re-fetch (e.g. right after creating an offer post).
  Future<void> refresh(String? userId) => fetchStatus(userId, force: true);

  /// Optimistically mark as provider immediately (before async re-fetch).
  void markAsProvider() {
    _isProvider = true;
    notifyListeners();
  }

  /// Called on logout.
  void reset() => _reset();

  void _reset() {
    if (!_isProvider && _lastFetchedUserId == null) return;
    _isProvider = false;
    _isLoading = false;
    _lastFetchedUserId = null;
    notifyListeners();
  }
}
