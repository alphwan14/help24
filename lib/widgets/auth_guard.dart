import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../screens/auth_screen.dart';

/// Auth guard utility for protecting actions that require authentication
/// 
/// The app remains FULLY USABLE without login:
/// - Browse Discover ✓
/// - View posts ✓
/// - Search ✓
/// - Filter ✓
/// 
/// Auth required ONLY for:
/// - Post content
/// - Apply/respond to posts
/// - Send messages
/// - Edit profile
/// 
/// Usage:
/// ```dart
/// AuthGuard.requireAuth(
///   context,
///   action: 'post content',
///   onAuthenticated: () {
///     // User is authenticated, proceed with action
///     _createPost();
///   },
/// );
/// ```
class AuthGuard {
  /// Check if user is authenticated and either execute action or show auth screen
  /// 
  /// [context] - BuildContext
  /// [action] - Description of the action (e.g., "post content", "send a message")
  /// [onAuthenticated] - Callback to execute when user is authenticated
  /// [showModal] - If true, shows auth as modal bottom sheet. If false, pushes full screen
  static Future<bool> requireAuth(
    BuildContext context, {
    required String action,
    required VoidCallback onAuthenticated,
    bool showModal = true,
  }) async {
    final authProvider = context.read<AuthProvider>();
    
    // If Firebase is not configured, allow action with guest mode
    // This ensures app works even without Firebase credentials
    if (!authProvider.isFirebaseConfigured) {
      debugPrint('⚠️ Firebase not configured - allowing action in guest mode');
      onAuthenticated();
      return true;
    }
    
    // If already logged in, execute action immediately
    if (authProvider.isLoggedIn) {
      onAuthenticated();
      return true;
    }
    
    // Show auth screen
    bool? authenticated;
    
    if (showModal) {
      authenticated = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        enableDrag: true,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.92,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: AuthScreen(
                action: action,
                isModal: true,
                onSuccess: () => Navigator.pop(context, true),
              ),
            );
          },
        ),
      );
    } else {
      authenticated = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => AuthScreen(action: action),
        ),
      );
    }
    
    // If authenticated, execute the original action
    if (authenticated == true) {
      // Small delay to ensure auth state is updated
      await Future.delayed(const Duration(milliseconds: 100));
      onAuthenticated();
      return true;
    }
    
    return false;
  }
  
  /// Check if user is authenticated without taking any action
  static bool isAuthenticated(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    // Allow if logged in OR if Firebase is not configured (guest mode)
    return authProvider.isLoggedIn || !authProvider.isFirebaseConfigured;
  }
  
  /// Get the current user ID (or null if not authenticated)
  static String? getUserId(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    return authProvider.currentUserId;
  }
  
  /// Get current user name (empty if not authenticated)
  static String getUserName(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    return authProvider.currentUserName;
  }
}
