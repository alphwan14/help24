import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../utils/phone_utils.dart';
import '../l10n/app_localizations.dart';
import '../models/user_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/location_provider.dart';
import '../services/notification_service.dart';
import '../services/user_profile_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';
import '../widgets/loading_empty_offline.dart';
import '../widgets/reputation_widgets.dart';
import 'auth_screen.dart';
import 'edit_profile_screen.dart';
import 'help_center_screen.dart';
import 'my_posts_screen.dart';
import 'terms_screen.dart';
import 'privacy_screen.dart';
import 'location_permission_explainer_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 20),

            // Identity + trust + activity + account — everything that needs the
            // user's row is fed by ONE stream inside _LoggedInSections (the old
            // layout ran two parallel 15s pollers on the same row).
            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                if (!auth.isLoggedIn) {
                  return Column(
                    children: [
                      _GuestProfile(onSignIn: () => _navigateToAuth(context)),
                      const SizedBox(height: 20),
                      _SettingsSection(
                        title: 'Account',
                        children: [
                          _SettingsTile(
                            icon: Iconsax.profile_circle,
                            title: 'Edit Profile',
                            subtitle: 'Sign in to edit your profile',
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _showAuthModalForEditProfile(context),
                          ),
                        ],
                      ),
                    ],
                  );
                }
                return _LoggedInSections(
                  uid: auth.currentUserId ?? '',
                  authUser: auth.currentUser!,
                );
              },
            ),
            const SizedBox(height: 16),

            // ── Preferences ─────────────────────────────────────────────────
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
                    // Wrapped in its own StatefulWidget for instant optimistic updates.
                    return _NotificationSwitchTile(uid: auth.currentUserId!);
                  },
                ),
                Consumer2<AuthProvider, LocationProvider>(
                  builder: (context, auth, location, _) {
                    if (!auth.isLoggedIn) {
                      return _SettingsTile(
                        icon: Icons.location_on_outlined,
                        title: 'Location Access',
                        subtitle: 'Sign in',
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _navigateToAuth(context),
                      );
                    }
                    final uid = auth.currentUserId ?? '';
                    String subtitle;
                    if (location.isGranted) {
                      subtitle = location.city == null || location.city!.isEmpty
                          ? 'Enabled'
                          : 'Enabled · ${location.city}';
                    } else if (location.isPermanentlyDenied) {
                      subtitle = 'Denied · enable in settings';
                    } else {
                      subtitle = 'Not enabled';
                    }
                    return _SettingsTile(
                      icon: Icons.location_on_outlined,
                      title: 'Location Access',
                      subtitle: subtitle,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final locationProvider = context.read<LocationProvider>();
                        await locationProvider.initializeForUser(uid);
                        if (!context.mounted) return;
                        if (locationProvider.isGranted) {
                          // Permission already granted — show manage sheet.
                          await showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) => _LocationSettingsSheet(userId: uid),
                          );
                        } else {
                          // Permission not yet granted — show the explainer.
                          await showModalBottomSheet<bool>(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) =>
                                LocationPermissionExplainerScreen(userId: uid),
                          );
                        }
                        if (!context.mounted) return;
                        final appProvider = context.read<AppProvider>();
                        await locationProvider.initializeForUser(uid);
                        if (!context.mounted) return;
                        appProvider.setPriorityLocationCity(locationProvider.city);
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

            _SettingsSection(
              title: AppLocalizations.of(context)?.t('support') ?? 'Support',
              children: [
                _SettingsTile(
                  icon: Iconsax.message_question,
                  title: AppLocalizations.of(context)?.t('help_center') ?? 'Help Center',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openHelpCenter(context),
                ),
                _SettingsTile(
                  icon: Iconsax.document_text,
                  title: AppLocalizations.of(context)?.t('terms_of_service') ?? 'Terms of Service',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openTerms(context),
                ),
                _SettingsTile(
                  icon: Iconsax.shield_tick,
                  title: AppLocalizations.of(context)?.t('privacy_policy') ?? 'Privacy Policy',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openPrivacy(context),
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

            // Version — read from the installed package, never hard-coded.
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) => Text(
                snap.hasData ? 'Help24 v${snap.data!.version}' : 'Help24',
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
      MaterialPageRoute(
        builder: (context) => AuthScreen(
          isModal: false,
          onSuccess: () {
            if (context.mounted) Navigator.of(context).pop(true);
          },
        ),
      ),
    );
  }

  void _showAuthModalForEditProfile(BuildContext context) {
    showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: true,
      builder: (modalContext) => DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: Theme.of(modalContext).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: AuthScreen(
            action: 'edit your profile',
            isModal: true,
            onSuccess: () => Navigator.pop(modalContext, true),
          ),
        ),
      ),
    ).then((value) {
      if (value == true && context.mounted) {
        final auth = context.read<AuthProvider>();
        if (auth.currentUserId != null) _openEditProfile(context, null);
      }
    });
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

  void _openHelpCenter(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const HelpCenterScreen(),
      ),
    );
  }

  void _openTerms(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const TermsScreen(),
      ),
    );
  }

  void _openPrivacy(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const PrivacyScreen(),
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
              trailing: localeProvider.languageCode == 'en'
                  ? const Icon(Icons.check_rounded, color: AppTheme.primaryAccent)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                localeProvider.setLanguage('en');
              },
            ),
            ListTile(
              title: Text(l10n?.t('language_swahili') ?? 'Kiswahili'),
              subtitle: const Text('Coming soon'),
              trailing: const Icon(Icons.lock_outline_rounded, size: 18),
              onTap: () {
                Navigator.pop(ctx);
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Coming Soon'),
                    content: const Text(
                      'Swahili support is currently under development and will be available in a future update.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
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

/// Everything on the profile that needs the user's row: identity hero,
/// trust/reputation, My Activity, and the Account section — fed by a SINGLE
/// users stream (cached in State so rebuilds never re-subscribe), with the
/// ensure-profile-row repair attempted at most once per screen life and never
/// from inside build().
class _LoggedInSections extends StatefulWidget {
  final String uid;
  final dynamic authUser; // AppUser

  const _LoggedInSections({required this.uid, required this.authUser});

  @override
  State<_LoggedInSections> createState() => _LoggedInSectionsState();
}

class _LoggedInSectionsState extends State<_LoggedInSections> {
  late Stream<UserModel?> _stream = UserProfileService.watchUser(widget.uid);
  bool _ensureAttempted = false;

  @override
  void didUpdateWidget(covariant _LoggedInSections oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) {
      _stream = UserProfileService.watchUser(widget.uid);
      _ensureAttempted = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserModel?>(
      stream: _stream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: LoadingView(message: 'Loading profile...'),
          );
        }
        if (snap.data == null &&
            snap.connectionState != ConnectionState.waiting &&
            !_ensureAttempted) {
          _ensureAttempted = true;
          final user = widget.authUser;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            UserProfileService.ensureProfileDoc(
              uid: widget.uid,
              email: user.email,
              name: user.name ?? user.displayName,
              phone: user.phoneNumber,
            );
          });
        }
        final profile = snap.data;
        return Column(
          children: [
            _LoggedInProfile(profile: profile, authUser: widget.authUser),
            const SizedBox(height: 20),

            // ── My Activity ─────────────────────────────────────────────
            _SettingsSection(
              title: 'My Activity',
              children: [
                _MyPostsTile(uid: widget.uid),
              ],
            ),
            const SizedBox(height: 16),

            // ── Account ─────────────────────────────────────────────────
            _SettingsSection(
              title: 'Account',
              children: [
                _SettingsTile(
                  icon: Iconsax.profile_circle,
                  title: 'Edit Profile',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EditProfileScreen(
                        uid: widget.uid,
                        initialProfile: profile,
                        emailFromAuth: widget.authUser.email ?? '',
                      ),
                    ),
                  ),
                ),
                _SettingsTile(
                  icon: Iconsax.card,
                  title: 'Payment Settings',
                  // The number is sensitive — masked here; the full value is
                  // only revealed behind the biometric gate in the sheet.
                  subtitle: (profile?.phone?.isNotEmpty == true)
                      ? maskPhone(profile!.phone!)
                      : 'M-Pesa number not set',
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => _PaymentSettingsSheet(
                      uid: widget.uid,
                      currentPhone: profile?.phone,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// "My Posts" activity tile: live server-side count, opens the management
/// list. The count future is cached in State (the parent stream emits every
/// 15s) and refreshed when returning from the My Posts screen.
class _MyPostsTile extends StatefulWidget {
  final String uid;

  const _MyPostsTile({required this.uid});

  @override
  State<_MyPostsTile> createState() => _MyPostsTileState();
}

class _MyPostsTileState extends State<_MyPostsTile> {
  late Future<int> _count = UserProfileService.getAuthoredPostsCount(widget.uid);

  @override
  void didUpdateWidget(covariant _MyPostsTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) {
      _count = UserProfileService.getAuthoredPostsCount(widget.uid);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: _count,
      builder: (context, snap) {
        final count = snap.data;
        return _SettingsTile(
          icon: Iconsax.document_text,
          title: 'My Posts',
          subtitle: count == null
              ? 'Requests, offers & job posts'
              : count == 1
                  ? '1 active post'
                  : '$count active posts',
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MyPostsScreen(userId: widget.uid),
            ),
          ).then((_) {
            if (mounted) {
              setState(() {
                _count = UserProfileService.getAuthoredPostsCount(widget.uid);
              });
            }
          }),
        );
      },
    );
  }
}

/// Profile identity hero for logged in users (users row, auth fallback).
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
    final avatarUrl = (profile?.profileImage != null && profile!.profileImage.isNotEmpty)
        ? profile!.profileImage
        : (authUser.photoUrl != null && authUser.photoUrl.isNotEmpty ? authUser.photoUrl : '');
    final initials = profile?.initials ?? authUser.initials;

    return Column(
      children: [
        // Profile Avatar — image only when profile_image/photoUrl is set, else initials
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
            borderRadius: BorderRadius.circular(50),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primaryAccent.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Center(
            child: avatarUrl.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(50),
                    child: CachedNetworkImage(
                      imageUrl: avatarUrl,
                      width: 100,
                      height: 100,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => const Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                        ),
                      ),
                      errorWidget: (_, __, ___) => Icon(
                        Icons.person_outline_rounded,
                        size: 44,
                        color: Colors.white70,
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
        if (profile?.profession.isNotEmpty == true) ...[
          const SizedBox(height: 6),
          Text(
            profile!.profession,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
        const SizedBox(height: 8),

        // Backend-sourced reputation: rating, completed jobs, completion rate,
        // dispute rate, open disputes, tier, member since. Post count moved to
        // the My Activity section (it's an action, not a trust signal).
        // authUser is AppUser (field `id`, not `uid`) — the old dynamic
        // `authUser.uid` call crashed at runtime whenever the users row was
        // still null.
        ReputationProfileSection(providerId: profile?.uid ?? authUser.id),
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
            borderRadius: BorderRadius.circular(50),
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

// ── Notification toggle — instant optimistic update ──────────────────────────
class _NotificationSwitchTile extends StatefulWidget {
  final String uid;
  const _NotificationSwitchTile({required this.uid});
  @override
  State<_NotificationSwitchTile> createState() => _NotificationSwitchTileState();
}

class _NotificationSwitchTileState extends State<_NotificationSwitchTile> {
  bool? _optimisticValue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return StreamBuilder<({bool notificationsEnabled, String language})>(
      stream: UserProfileService.watchUserPrefs(widget.uid),
      builder: (context, snap) {
        final actual = snap.data?.notificationsEnabled ?? true;
        final displayed = _optimisticValue ?? actual;
        return _SettingsTile(
          icon: Iconsax.notification,
          title: l10n?.t('notifications') ?? 'Notifications',
          trailing: Switch.adaptive(
            value: displayed,
            onChanged: (val) async {
              setState(() => _optimisticValue = val);
              try {
                if (val) {
                  await NotificationService.enableAndSaveToken(widget.uid);
                } else {
                  await NotificationService.disableAndRemoveToken(widget.uid);
                }
                if (mounted) setState(() => _optimisticValue = null);
              } catch (_) {
                if (mounted) setState(() => _optimisticValue = !val);
              }
            },
          ),
        );
      },
    );
  }
}

class _PaymentSettingsSheet extends StatefulWidget {
  final String uid;
  final String? currentPhone;
  const _PaymentSettingsSheet({required this.uid, this.currentPhone});
  @override
  State<_PaymentSettingsSheet> createState() => _PaymentSettingsSheetState();
}

class _PaymentSettingsSheetState extends State<_PaymentSettingsSheet> {
  late final TextEditingController _phoneController;
  bool _saving = false;
  String? _error;
  bool _unlocked = false;
  bool _authenticating = false;

  @override
  void initState() {
    super.initState();
    _phoneController = TextEditingController(text: widget.currentPhone ?? '');
    // Skip biometric gate when no number has been set yet
    _unlocked = widget.currentPhone == null || widget.currentPhone!.isEmpty;
  }

  @override
  void dispose() {
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _authenticate() async {
    setState(() { _authenticating = true; _error = null; });
    try {
      final localAuth = LocalAuthentication();
      final bool deviceSupported = await localAuth.isDeviceSupported();
      if (!deviceSupported) {
        // Device has no lock screen — skip gate
        if (mounted) setState(() { _unlocked = true; _authenticating = false; });
        return;
      }
      final bool ok = await localAuth.authenticate(
        localizedReason: 'Authenticate to change your M-Pesa number',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      if (mounted) setState(() { _unlocked = ok; _authenticating = false; });
    } on Exception catch (e) {
      if (mounted) {
        setState(() {
          _authenticating = false;
          _error = 'Authentication error: $e';
        });
      }
    }
  }

  Future<void> _save() async {
    final raw = _phoneController.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Enter your M-Pesa number.');
      return;
    }
    final normalized = normalizeKenyanNumber(raw);
    if (normalized == null) {
      setState(() => _error = 'Invalid number. Use 07XXXXXXXX or 254XXXXXXXXX.');
      return;
    }
    _phoneController.text = normalized;
    setState(() { _saving = true; _error = null; });
    try {
      await UserProfileService.saveMpesaPhone(widget.uid, normalized);
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('M-Pesa number saved.'),
            backgroundColor: AppTheme.successGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildHandleAndHeader(BuildContext context, bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 20),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Iconsax.mobile, color: AppTheme.primaryAccent, size: 20),
            ),
            const SizedBox(width: 12),
            Text('Payment Settings', style: Theme.of(context).textTheme.titleLarge),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: _unlocked ? _buildEditForm(context, isDark) : _buildLockedView(context, isDark),
      ),
    );
  }

  Widget _buildLockedView(BuildContext context, bool isDark) {
    final maskedPhone = widget.currentPhone != null && widget.currentPhone!.length > 6
        ? '${widget.currentPhone!.substring(0, 3)}••••••${widget.currentPhone!.substring(widget.currentPhone!.length - 3)}'
        : widget.currentPhone ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHandleAndHeader(context, isDark),
        const SizedBox(height: 24),
        // Current number display
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ),
          child: Row(
            children: [
              Icon(Iconsax.mobile, size: 20,
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('M-Pesa Number',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Text(maskedPhone,
                      style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
              const Spacer(),
              Icon(Iconsax.lock, size: 18,
                  color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _authenticating ? null : _authenticate,
            icon: _authenticating
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Iconsax.finger_scan, size: 18),
            label: Text(_authenticating ? 'Authenticating…' : 'Change Number'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: AppTheme.errorRed, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _buildEditForm(BuildContext context, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHandleAndHeader(context, isDark),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.primaryAccent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.primaryAccent.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Icon(Iconsax.info_circle, size: 18, color: AppTheme.primaryAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'This number is used for M-Pesa payments and payouts.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.primaryAccent),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'M-Pesa Number',
            hintText: '254XXXXXXXXX',
            prefixIcon: const Icon(Iconsax.mobile),
            errorText: _error,
          ),
          onChanged: (_) { if (_error != null) setState(() => _error = null); },
        ),
        const SizedBox(height: 8),
        Text(
          'Format: 254 followed by 9 digits (e.g. 254712345678)',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Save Number'),
          ),
        ),
      ],
    );
  }
}

// ─── Location Settings Sheet ──────────────────────────────────────────────────
// Shown when location permission is already granted. Lets the user refresh
// their stored location or disable in-app location usage.

class _LocationSettingsSheet extends StatefulWidget {
  final String userId;

  const _LocationSettingsSheet({required this.userId});

  @override
  State<_LocationSettingsSheet> createState() => _LocationSettingsSheetState();
}

class _LocationSettingsSheetState extends State<_LocationSettingsSheet> {
  bool _refreshing = false;
  bool _disabling = false;
  String? _feedback;

  Future<void> _refreshLocation() async {
    setState(() {
      _refreshing = true;
      _feedback = null;
    });
    try {
      final ok = await context
          .read<LocationProvider>()
          .captureAndStoreCurrentLocation(widget.userId);
      if (!mounted) return;
      setState(() {
        _feedback = ok ? 'Location updated.' : 'Could not get location. Try again.';
      });
      if (ok) {
        context.read<AppProvider>().setPriorityLocationCity(
              context.read<LocationProvider>().city,
            );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _disableLocation() async {
    setState(() {
      _disabling = true;
      _feedback = null;
    });
    try {
      await context
          .read<LocationProvider>()
          .disableLocation(widget.userId);
      if (!mounted) return;
      context.read<AppProvider>().setPriorityLocationCity(null);
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _disabling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    return Consumer<LocationProvider>(
      builder: (context, location, _) {
        final city = location.city;
        final lastUpdated = location.lastUpdated;

        return Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.fromLTRB(
            24,
            20,
            24,
            MediaQuery.of(context).viewInsets.bottom + 32,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: borderColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Header row
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppTheme.successGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.location_on_rounded,
                      color: AppTheme.successGreen,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Location Enabled',
                        style: TextStyle(
                          color: textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Location access is active',
                        style: TextStyle(color: AppTheme.successGreen, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Location details card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(
                      icon: Icons.place_rounded,
                      label: 'Current location',
                      value: (city != null && city.isNotEmpty)
                          ? city
                          : 'Not yet detected',
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      icon: Icons.access_time_rounded,
                      label: 'Last updated',
                      value: lastUpdated != null
                          ? formatRelativeTime(lastUpdated)
                          : 'Never',
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                    ),
                  ],
                ),
              ),

              // Inline feedback message
              if (_feedback != null) ...[
                const SizedBox(height: 12),
                Text(
                  _feedback!,
                  style: TextStyle(
                    color: _feedback!.contains('updated')
                        ? AppTheme.successGreen
                        : AppTheme.warningOrange,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Refresh location
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton.icon(
                  onPressed: (_refreshing || _disabling) ? null : _refreshLocation,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.my_location_rounded, size: 18),
                  label: Text(_refreshing ? 'Updating...' : 'Refresh Location'),
                ),
              ),
              const SizedBox(height: 10),

              // Disable location
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: (_refreshing || _disabling) ? null : _disableLocation,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.errorRed,
                    side: BorderSide(
                      color: (_refreshing || _disabling)
                          ? borderColor
                          : AppTheme.errorRed,
                    ),
                  ),
                  icon: _disabling
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: AppTheme.errorRed),
                        )
                      : const Icon(Icons.location_off_rounded, size: 18),
                  label: Text(_disabling ? 'Disabling...' : 'Disable Location'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color textPrimary;
  final Color textSecondary;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.textPrimary,
    required this.textSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
