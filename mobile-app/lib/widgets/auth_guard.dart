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
    
    // Require real authentication; no guest mode for posting/messaging
    if (!authProvider.isFirebaseConfigured) {
      debugPrint('⚠️ Firebase not configured - sign in required for this action');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sign-in is not configured. Contact support.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
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
    
    if (authenticated == true) {
      onAuthenticated();
      return true;
    }
    
    return false;
  }
  
  /// Check if user is authenticated without taking any action (real auth only; no guest)
  static bool isAuthenticated(BuildContext context) {
    return context.read<AuthProvider>().isLoggedIn;
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
