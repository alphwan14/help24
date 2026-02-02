import 'package:flutter/material.dart';
import '../widgets/custom_bottom_nav.dart';
import '../widgets/auth_guard.dart';
import 'discover_screen.dart';
import 'jobs_screen.dart';
import 'post_screen.dart';
import 'messages_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  bool _showPostScreen = false;

  void _onNavTap(int index) {
    if (index == 2) {
      // Post button - requires authentication
      AuthGuard.requireAuth(
        context,
        action: 'create a post',
        onAuthenticated: () {
          setState(() {
            _showPostScreen = true;
          });
        },
      );
    } else if (index == 3) {
      // Messages - requires authentication
      AuthGuard.requireAuth(
        context,
        action: 'view messages',
        onAuthenticated: () {
          setState(() {
            _currentIndex = 2; // Messages is index 2 in the stack
            _showPostScreen = false;
          });
        },
      );
    } else {
      setState(() {
        _currentIndex = index > 2 ? index - 1 : index;
        _showPostScreen = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _showPostScreen
          ? PostScreen(
              onComplete: () {
                setState(() {
                  _showPostScreen = false;
                  _currentIndex = 0;
                });
              },
            )
          : IndexedStack(
              index: _currentIndex,
              children: const [
                DiscoverScreen(),
                JobsScreen(),
                MessagesScreen(),
                ProfileScreen(),
              ],
            ),
      bottomNavigationBar: _showPostScreen
          ? null
          : CustomBottomNav(
              currentIndex: _getNavIndex(),
              onTap: _onNavTap,
            ),
    );
  }

  int _getNavIndex() {
    // Map the actual tab index to the nav index (accounting for center button)
    if (_currentIndex >= 2) {
      return _currentIndex + 1;
    }
    return _currentIndex;
  }
}
