import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../config/app_urls.dart';
import '../l10n/app_localizations.dart';
import '../models/user_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/locale_provider.dart';
import '../services/notification_service.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import 'auth_screen.dart';
import 'edit_profile_screen.dart';
import 'web_view_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 20),

            // Profile Section (Dynamic based on auth state)
            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                if (!auth.isLoggedIn) {
                  return _GuestProfile(
                    onSignIn: () => _navigateToAuth(context),
                  );
                }
                final uid = auth.currentUserId ?? '';
                return StreamBuilder<UserModel?>(
                  stream: UserProfileService.watchUser(uid),
                  builder: (context, snap) {
                    if (snap.data == null && snap.connectionState != ConnectionState.waiting) {
                      UserProfileService.ensureProfileDoc(
                        uid: uid,
                        email: auth.currentUser!.email,
                        name: auth.currentUser!.name ?? auth.currentUser!.displayName,
                        phone: auth.currentUser!.phoneNumber,
                      );
                    }
                    return _LoggedInProfile(
                      profile: snap.data,
                      authUser: auth.currentUser!,
                    );
                  },
                );
              },
            ),

            const SizedBox(height: 20),

            // Settings Section
            _SettingsSection(
              title: AppLocalizations.of(context)?.t('preferences') ?? 'Preferences',
              children: [
                Consumer<AppProvider>(
                  builder: (context, provider, _) {
                    return _SettingsTile(
                      icon: provider.isDarkMode ? Iconsax.moon : Iconsax.sun_1,
                      title: AppLocalizations.of(context)?.t('dark_mode') ?? 'Dark Mode',
                      trailing: Switch.adaptive(
                        value: provider.isDarkMode,
                        onChanged: (_) => provider.toggleTheme(),
                        activeTrackColor: AppTheme.primaryAccent,
                        thumbColor: WidgetStateProperty.all(Colors.white),
                      ),
                    );
                  },
                ),
                Consumer<AuthProvider>(
                  builder: (context, auth, _) {
                    if (!auth.isLoggedIn) {
                      return _SettingsTile(
                        icon: Iconsax.notification,
                        title: AppLocalizations.of(context)?.t('notifications') ?? 'Notifications',
                        subtitle: AppLocalizations.of(context)?.t('sign_in') ?? 'Sign in',
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _navigateToAuth(context),
                      );
                    }
                    final uid = auth.currentUserId ?? '';
                    return StreamBuilder<({bool notificationsEnabled, String language})>(
                      stream: UserProfileService.watchUserPrefs(uid),
                      builder: (context, snap) {
                        final enabled = snap.data?.notificationsEnabled ?? true;
                        return _SettingsTile(
                          icon: Iconsax.notification,
                          title: AppLocalizations.of(context)?.t('notifications') ?? 'Notifications',
                          subtitle: enabled
                              ? (AppLocalizations.of(context)?.t('notifications_on') ?? 'On')
                              : (AppLocalizations.of(context)?.t('notifications_off') ?? 'Off'),
                          trailing: Switch.adaptive(
                            value: enabled,
                            onChanged: (value) async {
                              if (value) {
                                await NotificationService.enableAndSaveToken(uid);
                              } else {
                                await NotificationService.disableAndRemoveToken(uid);
                              }
                            },
                            activeTrackColor: AppTheme.primaryAccent,
                            thumbColor: WidgetStateProperty.all(Colors.white),
                          ),
                        );
                      },
                    );
                  },
                ),
                Consumer<AuthProvider>(
                  builder: (context, auth, _) {
                    final localeProvider = context.watch<LocaleProvider>();
                    final langLabel = localeProvider.languageCode == 'sw'
                        ? (AppLocalizations.of(context)?.t('language_swahili') ?? 'Kiswahili')
                        : (AppLocalizations.of(context)?.t('language_english') ?? 'English');
                    if (!auth.isLoggedIn) {
                      return _SettingsTile(
                        icon: Iconsax.language_square,
                        title: AppLocalizations.of(context)?.t('language') ?? 'Language',
                        subtitle: langLabel,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _navigateToAuth(context),
                      );
                    }
                    return _SettingsTile(
                      icon: Iconsax.language_square,
                      title: AppLocalizations.of(context)?.t('language') ?? 'Language',
                      subtitle: langLabel,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showLanguageSheet(context, auth.currentUserId!, localeProvider),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Account Section (only show if logged in)
            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                if (!auth.isLoggedIn) return const SizedBox.shrink();
                final uid = auth.currentUserId ?? '';
                return StreamBuilder<UserModel?>(
                  stream: UserProfileService.watchUser(uid),
                  builder: (context, snap) {
                    return Column(
                      children: [
                        _SettingsSection(
                          title: 'Account',
                          children: [
                            _SettingsTile(
                              icon: Iconsax.profile_circle,
                              title: 'Edit Profile',
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _openEditProfile(context, snap.data),
                            ),
                        _SettingsTile(
                          icon: Iconsax.security_safe,
                          title: 'Privacy & Security',
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {},
                        ),
                            _SettingsTile(
                              icon: Iconsax.card,
                              title: 'Payment Methods',
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () {},
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                    );
                  },
                );
              },
            ),

            _SettingsSection(
              title: AppLocalizations.of(context)?.t('support') ?? 'Support',
              children: [
                _SettingsTile(
                  icon: Iconsax.message_question,
                  title: AppLocalizations.of(context)?.t('help_center') ?? 'Help Center',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {},
                ),
                _SettingsTile(
                  icon: Iconsax.document_text,
                  title: AppLocalizations.of(context)?.t('terms_of_service') ?? 'Terms of Service',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openWebView(context, AppUrls.termsOfService, 'Terms of Service'),
                ),
                _SettingsTile(
                  icon: Iconsax.shield_tick,
                  title: AppLocalizations.of(context)?.t('privacy_policy') ?? 'Privacy Policy',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openWebView(context, AppUrls.privacyPolicy, 'Privacy Policy'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Login/Logout Button
            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                if (auth.isLoggedIn) {
                  return Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                      ),
                    ),
                    child: _SettingsTile(
                      icon: Iconsax.logout,
                      title: 'Log Out',
                      iconColor: AppTheme.errorRed,
                      titleColor: AppTheme.errorRed,
                      onTap: () => _showLogoutDialog(context, auth),
                    ),
                  );
                } else {
                  return Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                      ),
                    ),
                    child: _SettingsTile(
                      icon: Iconsax.login,
                      title: 'Sign In',
                      iconColor: AppTheme.primaryAccent,
                      titleColor: AppTheme.primaryAccent,
                      onTap: () => _navigateToAuth(context),
                    ),
                  );
                }
              },
            ),
            const SizedBox(height: 32),

            // Version
            Text(
              'Help24 v1.0.0',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  void _navigateToAuth(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AuthScreen()),
    );
  }

  void _openEditProfile(BuildContext context, UserModel? profile) {
    final auth = context.read<AuthProvider>();
    final uid = auth.currentUserId;
    if (uid == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => EditProfileScreen(
          uid: uid,
          initialProfile: profile,
          emailFromAuth: auth.currentUser?.email ?? '',
        ),
      ),
    );
  }

  void _openWebView(BuildContext context, String url, String title) {
    final l10n = AppLocalizations.of(context);
    final pageTitle = title == 'Terms of Service'
        ? (l10n?.t('terms_of_service') ?? title)
        : (title == 'Privacy Policy' ? (l10n?.t('privacy_policy') ?? title) : title);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WebViewScreen(title: pageTitle, url: url),
      ),
    );
  }

  void _showLanguageSheet(BuildContext context, String uid, LocaleProvider localeProvider) {
    final l10n = AppLocalizations.of(context);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(l10n?.t('language_english') ?? 'English'),
              onTap: () {
                Navigator.pop(ctx);
                localeProvider.setLanguage('en');
              },
            ),
            ListTile(
              title: Text(l10n?.t('language_swahili') ?? 'Kiswahili'),
              onTap: () {
                Navigator.pop(ctx);
                localeProvider.setLanguage('sw');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showLogoutDialog(BuildContext context, AuthProvider auth) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log Out'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await auth.signOut();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.white),
                        SizedBox(width: 12),
                        Text('Logged out successfully'),
                      ],
                    ),
                    behavior: SnackBarBehavior.floating,
                    backgroundColor: AppTheme.successGreen,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                );
              }
            },
            child: Text(
              'Log Out',
              style: TextStyle(color: AppTheme.errorRed),
            ),
          ),
        ],
      ),
    );
  }
}

/// Profile widget for logged in users (Firestore profile or auth fallback).
class _LoggedInProfile extends StatelessWidget {
  final UserModel? profile;
  final dynamic authUser; // AppUser

  const _LoggedInProfile({this.profile, required this.authUser});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final name = profile?.displayName ?? authUser.displayName;
    final email = profile?.email ?? authUser.email;
    final secondary = email.isNotEmpty ? email : (authUser.phoneNumber ?? '');
    final avatarUrl = profile?.profileImage.isNotEmpty == true
        ? profile!.profileImage
        : authUser.photoUrl;
    final initials = profile?.initials ?? authUser.initials;

    return Column(
      children: [
        // Profile Avatar
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppTheme.primaryAccent,
                AppTheme.secondaryAccent,
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primaryAccent.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Center(
            child: avatarUrl != null && avatarUrl.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.network(
                      avatarUrl,
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Text(
                        initials,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  )
                : Text(
                    initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 20),

        // Name
        Text(
          name,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 4),
        Text(
          secondary,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (profile?.bio.isNotEmpty == true) ...[
          const SizedBox(height: 8),
          Text(
            profile!.bio,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  fontStyle: FontStyle.italic,
                ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 8),

        // Stats Row
        Container(
          margin: const EdgeInsets.symmetric(vertical: 20),
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              const _StatItem(value: '0', label: 'Posts'),
              Container(
                width: 1,
                height: 40,
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              ),
              const _StatItem(value: '-', label: 'Rating'),
              Container(
                width: 1,
                height: 40,
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              ),
              const _StatItem(value: '0', label: 'Completed'),
            ],
          ),
        ),
      ],
    );
  }
}

/// Profile widget for guest users
class _GuestProfile extends StatelessWidget {
  final VoidCallback onSignIn;
  
  const _GuestProfile({required this.onSignIn});
  
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Column(
      children: [
        // Guest Avatar
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              width: 2,
            ),
          ),
          child: Center(
            child: Icon(
              Iconsax.user,
              color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              size: 44,
            ),
          ),
        ),
        const SizedBox(height: 20),

        Text(
          'Not signed in',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Sign in to access all features',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
          ),
        ),
        const SizedBox(height: 20),

        // Sign in button
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton.icon(
            onPressed: onSignIn,
            icon: const Icon(Iconsax.login),
            label: const Text('Sign In'),
          ),
        ),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  final String value;
  final String label;

  const _StatItem({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 12),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? iconColor;
  final Color? titleColor;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.iconColor,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: (iconColor ?? AppTheme.primaryAccent).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                icon,
                color: iconColor ?? (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                size: 20,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: titleColor,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
