import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/provider_service.dart';

/// Tracks whether the logged-in user is a registered provider.
/// Source of truth is the Supabase `providers` table (matched by phone_login).
/// Always call [fetchStatus] after login and [refresh] after registration.
class ProviderStatusProvider extends ChangeNotifier {
  bool _isProvider = false;
  bool _isLoading = false;
  Map<String, dynamic>? _providerData;
  String? _lastFetchedPhone;

  bool get isProvider => _isProvider;
  bool get isLoading => _isLoading;
  Map<String, dynamic>? get providerData => _providerData;

  /// Fetch provider status from Supabase for the given phone number.
  /// Skips the request if the same phone was already fetched (unless [force] is true).
  Future<void> fetchStatus(String? phone, {bool force = false}) async {
    if (phone == null || phone.isEmpty) {
      _reset();
      return;
    }

    final normalized = ProviderService.normalizePhone(phone);

    if (!force && normalized == _lastFetchedPhone && !_isLoading) return;

    _isLoading = true;
    notifyListeners();

    try {
      debugPrint('[ProviderStatus] Fetching provider record for phone: $normalized');

      final data = await Supabase.instance.client
          .from('providers')
          .select()
          .eq('phone_login', normalized)
          .maybeSingle();

      debugPrint('[ProviderStatus] isProvider=${data != null}  data=$data');

      _isProvider = data != null;
      _providerData = data != null ? Map<String, dynamic>.from(data as Map) : null;
      _lastFetchedPhone = normalized;
    } catch (e) {
      debugPrint('[ProviderStatus] Error fetching provider status: $e');
      // Keep last known state on error so UI doesn't flicker to "not provider"
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Force re-fetch (e.g. called right after successful registration).
  Future<void> refresh(String? phone) => fetchStatus(phone, force: true);

  /// Immediately mark user as provider after successful registration
  /// so the UI updates before the async re-fetch completes.
  void markAsProvider(Map<String, dynamic> data) {
    _isProvider = true;
    _providerData = Map<String, dynamic>.from(data);
    notifyListeners();
  }

  /// Called on logout — resets all provider state.
  void reset() => _reset();

  void _reset() {
    if (!_isProvider && _providerData == null && _lastFetchedPhone == null) return;
    _isProvider = false;
    _isLoading = false;
    _providerData = null;
    _lastFetchedPhone = null;
    notifyListeners();
  }
}
