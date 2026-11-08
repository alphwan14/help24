import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import '../config/app_urls.dart';
import '../utils/action_feedback.dart';
import '../utils/error_mapper.dart';
import '../utils/external_links.dart';
import '../utils/phone_utils.dart';
import '../l10n/app_localizations.dart';
import '../models/moderation.dart';
import '../models/payout_models.dart';
import '../models/profile_completion.dart';
import '../models/profile_setup.dart';
import '../models/theme_preference.dart';
import '../models/user_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/location_provider.dart';
import '../services/account_status_service.dart';
import '../services/current_location_service.dart' show CurrentLocationResult;
import '../services/notification_service.dart';
import '../services/notification_toggle_state.dart';
import '../services/payout_authority.dart';
import '../services/payout_service.dart';
import '../services/reputation_service.dart';
import '../services/verification_service.dart';
import '../services/user_profile_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../utils/time_utils.dart';
import '../widgets/primitives.dart';
import '../widgets/auth/email_verification_banner.dart';
import '../widgets/auth_guard.dart';
import '../widgets/profile_widgets.dart';
import 'professional_profile_screen.dart';
import 'sign_in_methods_screen.dart';
import 'agent_code_screen.dart';
import '../services/agent_code_service.dart';
import '../services/auth_service.dart';
import 'promotion/promote_business_screen.dart';
import 'provider/payout_destinations_screen.dart';
import 'provider/provider_card_screen.dart';
import 'provider/verification_screen.dart';
import '../widgets/provider_gate.dart';
import 'provider/provider_onboarding_screen.dart';
import 'location_permission_explainer_screen.dart';
import 'account_status_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.gutter),
        child: Column(
          children: [
            const SizedBox(height: AppSpace.xl),

            // Identity + trust + activity + account, everything that needs the
            // user's row is fed by ONE stream inside _LoggedInSections (the old
            // layout ran two parallel 15s pollers on the same row).
            Consumer<AuthProvider>(
              builder: (context, auth, _) {
                if (!auth.isLoggedIn) {
                  return Column(
                    children: [
                      _GuestProfile(onSignIn: () => _navigateToAuth(context)),
                      _SettingsSection(
                        title: 'Account',
                        children: [
                          _SettingsTile(
                            icon: AppIcons.account,
                            title: 'Professional profile',
                            trailing: const Icon(AppIcons.disclosure),
                            onTap: () => _showAuthModalForEditProfile(context),
                          ),
                        ],
                      ),
                    ],
                  );
                }
                return Column(
                  children: [
                    // Asks (never forces) an email-account holder to confirm
                    // their address, the account-recovery path depends on it.
                    const EmailVerificationBanner(),
                    _LoggedInSections(
                      uid: auth.currentUserId ?? '',
                      authUser: auth.currentUser!,
                    ),
                  ],
                );
              },
            ),
            // ── Preferences ─────────────────────────────────────────────────
            _SettingsSection(
              title: AppLocalizations.of(context)?.t('preferences') ?? 'Preferences',
              children: [
                // Theme, three explicit choices instead of a boolean switch.
                // "Device Default" is a first-class option (and the default for
                // new installs), so the app can follow the OS schedule.
                Consumer<AppProvider>(
                  builder: (context, provider, _) {
                    final preference = provider.themePreference;
                    return _SettingsTile(
                      icon: preference.icon,
                      title: AppLocalizations.of(context)?.t('theme') ?? 'Theme',
                      value: preference.label,
                      trailing: const Icon(AppIcons.disclosure),
                      onTap: () => _showThemeSheet(context, provider),
                    );
                  },
                ),
                Consumer<AuthProvider>(
                  builder: (context, auth, _) {
                    if (!auth.isLoggedIn) {
                      return _SettingsTile(
                        icon: AppIcons.notifications,
                        title: AppLocalizations.of(context)?.t('notifications') ?? 'Notifications',
                        trailing: const Icon(AppIcons.disclosure),
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
                        icon: AppIcons.location,
                        title: 'Location access',
                        trailing: const Icon(AppIcons.disclosure),
                        onTap: () => _navigateToAuth(context),
                      );
                    }
                    final uid = auth.currentUserId ?? '';
                    // STATE, NOT INSTRUCTIONS. Every branch used to append what
                    // to do about it, "tap to turn on", "enable in settings",
                    // "Turn on location in device settings", which is both
                    // longer than the column and redundant: the row is
                    // tappable, and the screen it opens says what to do. The
                    // distinction between "we cannot ask again" (Denied) and
                    // "we have not asked" (Off) is kept, because they lead
                    // somewhere different.
                    String subtitle;
                    if (!location.isGranted) {
                      subtitle =
                          location.isPermanentlyDenied ? 'Denied' : 'Off';
                    } else if (!location.serviceEnabled) {
                      // Permission granted but the OS location toggle is off,
                      // mirror that immediately instead of claiming "On".
                      subtitle = 'Off in settings';
                    } else if (location.isLocationOn) {
                      subtitle = location.city == null || location.city!.isEmpty
                          ? 'On'
                          : 'On, ${location.city}';
                    } else {
                      // OS is fine, but the user disabled location in-app.
                      subtitle = 'Off';
                    }
                    return _SettingsTile(
                      icon: AppIcons.location,
                      title: 'Location access',
                      value: subtitle,
                      trailing: const Icon(AppIcons.disclosure),
                      onTap: () async {
                        final locationProvider = context.read<LocationProvider>();
                        await locationProvider.initializeForUser(uid);
                        if (!context.mounted) return;
                        if (locationProvider.isGranted) {
                          // Permission already granted, show manage sheet.
                          await showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (_) => _LocationSettingsSheet(userId: uid),
                          );
                        } else {
                          // Permission not yet granted, show the explainer.
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
                        appProvider.setViewer(
                          userId: uid,
                          latitude: locationProvider.latitude,
                          longitude: locationProvider.longitude,
                        );
                      },
                    );
                  },
                ),
                // LANGUAGE, shown only when there is more than one language
                // the app can actually be used in.
                //
                // There is one. The row opened a sheet whose only selectable
                // option was the one already selected, and whose other option
                // carried a padlock and a "coming soon" dialog: a setting that
                // cannot be set, costing a tap to find that out. The honest
                // version of "Kiswahili is not ready" is not offering it.
                //
                // `LocaleProvider._deliverable` is the switch, and its doc
                // records the coverage that has to exist first, 39 keys today,
                // every call site inside this one file. Restore this row in the
                // same change that adds 'sw' to it.
                if (LocaleProvider.offersAChoice)
                  Consumer<AuthProvider>(
                    builder: (context, auth, _) {
                      final localeProvider = context.watch<LocaleProvider>();
                      final langLabel = localeProvider.languageCode == 'sw'
                          ? (AppLocalizations.of(context)?.t('language_swahili') ?? 'Kiswahili')
                          : (AppLocalizations.of(context)?.t('language_english') ?? 'English');
                      return _SettingsTile(
                        icon: AppIcons.language,
                        title: AppLocalizations.of(context)?.t('language') ?? 'Language',
                        value: langLabel,
                        trailing: const Icon(AppIcons.disclosure),
                        onTap: auth.isLoggedIn
                            ? () => _showLanguageSheet(
                                context, auth.currentUserId!, localeProvider)
                            : () => _navigateToAuth(context),
                      );
                    },
                  ),
              ],
            ),

            _SettingsSection(
              title: AppLocalizations.of(context)?.t('support') ?? 'Support',
              children: [
                _SettingsTile(
                  icon: AppIcons.help,
                  title: _sentenceCase(AppLocalizations.of(context)?.t('help_center') ?? 'Help centre'),
                  trailing: const _ExternalTrailing(),
                  onTap: () => _openHelpCenter(context),
                ),
                _SettingsTile(
                  icon: AppIcons.support,
                  title: _sentenceCase(AppLocalizations.of(context)?.t('contact_support') ?? 'Contact support'),
                  trailing: const _ExternalTrailing(),
                  onTap: () => _openSupport(context),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xl),

            // THE FOOTER IS TYPE, NOT ROWS.
            //
            // Sign out was a red row in a card of its own, and Terms and
            // Privacy were full rows beside Help and Support. A footer of
            // plain text reads calmer: one action, two quiet links, the
            // version. Sign out is an action in place, so it has no chevron
            // and no icon arguing about direction.
            Consumer<AuthProvider>(
              builder: (context, auth, _) => _FooterAction(
                label: auth.isLoggedIn ? 'Sign out' : 'Sign in',
                color: auth.isLoggedIn
                    ? AppColors.of(context).criticalText
                    : AppColors.of(context).contentPrimary,
                onTap: auth.isLoggedIn
                    ? () => _showLogoutDialog(context, auth)
                    : () => _navigateToAuth(context),
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _FooterLink(
                  label: _sentenceCase(AppLocalizations.of(context)?.t('terms_of_service') ?? 'Terms of service'),
                  onTap: () => _openTerms(context),
                ),
                const SizedBox(width: AppSpace.xl),
                _FooterLink(
                  label: _sentenceCase(AppLocalizations.of(context)?.t('privacy_policy') ?? 'Privacy policy'),
                  onTap: () => _openPrivacy(context),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),

            // Version: read from the installed package, never hard-coded.
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snap) => Text(
                snap.hasData ? 'Help24 v${snap.data!.version}' : 'Help24',
                style: AppTypeScale.meta.copyWith(
                  fontFamily: AppTypeScale.family,
                  color: AppColors.of(context).contentTertiary,
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
          ],
        ),
      ),
    );
  }

  /// Sign in from the Profile tab.
  ///
  /// Routed through [AuthGuard] rather than pushing [AuthScreen] directly:
  /// these two entry points each had their own copy of the presentation, and a
  /// copy is exactly how one of them ends up depending on a pop result again.
  /// There is now one implementation, with one dismissal rule.
  void _navigateToAuth(BuildContext context) {
    unawaited(AuthGuard.present(context, showModal: false));
  }

  void _showAuthModalForEditProfile(BuildContext context) {
    unawaited(
      AuthGuard.requireAuth(
        context,
        action: 'edit your profile',
        // Runs when the user is signed in after the screen closes, however it
        // closed. Previously this was gated on the sheet popping with `true`,
        // so a drag-dismiss after a successful sign-in silently dropped the
        // edit the user had asked for.
        onAuthenticated: () => _openEditProfile(context, null),
      ),
    );
  }

  void _openEditProfile(BuildContext context, UserModel? profile) {
    final auth = context.read<AuthProvider>();
    final uid = auth.currentUserId;
    if (uid == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProfessionalProfileScreen(
          uid: uid,
          initialProfile: profile,
          emailFromAuth: auth.currentUser?.email ?? '',
          phoneFromAuth: auth.currentUser?.phoneNumber,
        ),
      ),
    );
  }

  // Support/legal rows are now gateways to the website, one source of truth on
  // help24.co.ke, opened in an in-app browser tab. See utils/external_links.dart.
  void _openHelpCenter(BuildContext context) =>
      openHelp24Url(context, AppUrls.helpCentre);

  void _openSupport(BuildContext context) =>
      openHelp24Url(context, AppUrls.supportPortal);

  void _openTerms(BuildContext context) =>
      openHelp24Url(context, AppUrls.termsOfService);

  void _openPrivacy(BuildContext context) =>
      openHelp24Url(context, AppUrls.privacyPolicy);

  /// Theme picker. Applies on tap (the whole app re-themes underneath the
  /// sheet, so the choice is visible before it is confirmed) and closes.
  void _showThemeSheet(BuildContext context, AppProvider provider) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
            borderRadius: AppRadius.sheetTop,
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SheetHandle(margin: EdgeInsets.only(bottom: 20)),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text('Theme', style: Theme.of(sheetContext).textTheme.titleLarge),
                ),
                Consumer<AppProvider>(
                  builder: (context, live, _) => Column(
                    children: [
                      for (final option in ThemePreference.values)
                        _ThemeOptionTile(
                          option: option,
                          selected: live.themePreference == option,
                          onTap: () {
                            live.setThemePreference(option);
                            Navigator.pop(sheetContext);
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
                  ? const Icon(AppIcons.check, color: AppTheme.primaryAccent)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                localeProvider.setLanguage('en');
              },
            ),
            ListTile(
              title: Text(l10n?.t('language_swahili') ?? 'Kiswahili'),
              subtitle: const Text('Coming soon'),
              trailing: const Icon(AppIcons.locked, size: 18),
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

  /// ONE VERB FOR ONE ACTION.
  ///
  /// Everywhere else in Help24 the user "signs in". Here they were asked to
  /// "Log Out", told they had "Logged out successfully", and shown a green
  /// tick for it. Three things wrong in one dialog: a second vocabulary for
  /// the same session, a confirmation nobody needs (the button says what it
  /// does, and the way back is one tap), and a success celebration for an
  /// action whose result is plainly visible on the screen behind it.
  ///
  /// The confirmation itself stays, signing out drops the session on a shared
  /// or borrowed phone and the mis-tap is worth catching, but it now asks the
  /// only question that matters and says what it costs.
  void _showLogoutDialog(BuildContext context, AuthProvider auth) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          "You'll need to sign in again to post, apply or message.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await auth.signOut();
            },
            child: Text(
              'Sign out',
              style: TextStyle(color: AppTheme.errorRed),
            ),
          ),
        ],
      ),
    );
  }
}

/// Everything on the profile that needs the user's row: identity hero,
/// trust/reputation, My Activity, and the Account section, fed by a SINGLE
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

  // ── Setup state for "Get ready to work" ─────────────────────────────
  // Read here, not in the row, because the Business rows depend on it too:
  // while the row shows, the rows for the same steps are hidden.
  bool? _idVerified;
  bool? _hasPayout;
  bool _payoutAvailable = true;
  bool _setupLoaded = false;

  /// Reads the two facts the profile row does not carry: identity check and
  /// payout number. A failed read leaves its fact null, which hides the setup
  /// row and lists the separate rows instead.
  Future<void> _loadSetup() async {
    bool? idVerified;
    bool? hasPayout;
    var payoutAvailable = true;
    try {
      idVerified = (await VerificationService.myStatus()).idVerified;
    } catch (_) {
      idVerified = null;
    }
    try {
      final destinations = await PayoutService.listDestinations(widget.uid);
      hasPayout = destinations.any((d) => d.status == PayoutDestinationStatus.active);
    } on PayoutException catch (e) {
      if (e.featureUnavailable) {
        payoutAvailable = false;
      } else {
        hasPayout = null;
      }
    } catch (_) {
      hasPayout = null;
    }
    if (!mounted) return;
    setState(() {
      _idVerified = idVerified;
      _hasPayout = hasPayout;
      _payoutAvailable = payoutAvailable;
      _setupLoaded = true;
    });
  }

  /// Whether "Who helped you join?" applies to this account, the SERVER's
  /// answer (my_agent_credit.can_change: the first 3 days). Hidden until it
  /// says yes, and for good after: past the window the row is clutter.
  bool _agentCodesOpen = false;

  Future<void> _loadAgentWindow() async {
    final credit = await AgentCodeService.myCredit();
    if (mounted) setState(() => _agentCodesOpen = credit?.canChange ?? false);
  }

  @override
  void initState() {
    super.initState();
    _loadAgentWindow();
    _loadSetup();
  }

  @override
  void didUpdateWidget(covariant _LoggedInSections oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) {
      _stream = UserProfileService.watchUser(widget.uid);
      _ensureAttempted = false;
      _agentCodesOpen = false;
      _setupLoaded = false;
      _loadAgentWindow();
      _loadSetup();
    }
  }

  /// Re-subscribe so an edit made on the Professional Profile is reflected the
  /// instant the user comes back, instead of on the next 15s poll tick.
  void _resubscribe() {
    if (!mounted) return;
    setState(() => _stream = UserProfileService.watchUser(widget.uid));
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<UserModel?>(
      stream: _stream,
      builder: (context, snap) {
        // Never block the whole screen (settings, logout, activity) on the
        // profile fetch. We already hold the signed-in user, so the header
        // renders immediately from [authUser] and upgrades in place when the
        // richer Supabase profile arrives. This also means a slow or failed
        // fetch can no longer strand the user on a "Loading profile…" spinner,
        // watchUser emits null on failure (bounded by the client timeout), and
        // null simply falls back to authUser below.
        if (snap.data == null &&
            snap.connectionState != ConnectionState.waiting &&
            !_ensureAttempted) {
          _ensureAttempted = true;
          final user = widget.authUser;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Explicitly unawaited: nothing here can catch a rejection, which
            // is exactly why ensureProfileDoc is contractually non-throwing.
            unawaited(UserProfileService.ensureProfileDoc(
              uid: widget.uid,
              email: user.email,
              name: user.name ?? user.displayName,
              phone: user.phoneNumber,
            ));
          });
        }
        final profile = snap.data;
        final isProvider = ProviderReadiness.of(
          profile,
          fallbackPhone: widget.authUser.phoneNumber,
        ).isReady;
        final completion = ProfileCompletion.of(
          profile,
          fallbackPhone: widget.authUser.phoneNumber,
        );
        final setup = _setupLoaded
            ? ProfileSetup.evaluate(
                profileComplete: completion.isComplete,
                isProvider: isProvider,
                idVerified: _idVerified,
                hasPayout: _hasPayout,
                payoutAvailable: _payoutAvailable,
              )
            : null;
        // While the setup row shows, it is the one place its steps live.
        final setupShowing = setup != null && !setup.isComplete;

        // ── Business ───────────────────────────────────────────────────
        // A member who does not offer services yet sees one way in, and
        // only when the setup row is not already offering it. A provider
        // sees their tools; the identity check joins them once setup is
        // done (it also holds the Care check, so it stays useful after).
        // Payout numbers moved to Account > Payments.
        final businessRows = <Widget>[
          if (!isProvider && !setupShowing)
            _SettingsTile(
              icon: AppIcons.provider,
              title: 'Offer your services',
              trailing: const Icon(AppIcons.disclosure),
              onTap: () => _openSetupStep(SetupStep.offerServices, profile),
            ),
          if (isProvider)
            _SettingsTile(
              icon: AppIcons.providerCard,
              title: 'My Help24 card',
              trailing: const Icon(AppIcons.disclosure),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => ProviderCardScreen(uid: widget.uid)),
              ),
            ),
          // Provider vetting (migration 135): the ID check (badge for anyone;
          // required for tutoring, driving, security, house cleaning) and
          // the Care check (babysitting, caregiving).
          if (isProvider && !setupShowing)
            _SettingsTile(
              icon: AppIcons.verifiedProvider,
              title: 'Verify your identity',
              trailing: const Icon(AppIcons.disclosure),
              onTap: () => _openSetupStep(SetupStep.verifyIdentity, profile),
            ),
          if (isProvider)
            _SettingsTile(
              icon: AppIcons.promote,
              title: 'Promote business',
              trailing: const Icon(AppIcons.disclosure),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => PromoteBusinessScreen(uid: widget.uid)),
              ),
            ),
        ];
        return Column(
          children: [
            // Only when something is wrong. "Good standing" was a row that
            // said nothing on every visit; a problem now gets one banner at
            // the top with the way to read or appeal it.
            const _AccountStandingBanner(),
            _LoggedInProfile(profile: profile, authUser: widget.authUser),
            const SizedBox(height: AppSpace.lg),
            // Replaces the "New on Help24 / Stats appear after your first
            // completed job" card: a member with no record is shown what to
            // do next, not an empty report.
            if (setupShowing)
              _ProfileSetupRow(
                setup: setup,
                onTap: () => _openSetupStep(setup.next!, profile),
              ),
            // Nothing until there is a completed job; then one flat row.
            _ProfileStats(uid: widget.uid),

            // ── "My Activity" USED TO BE HERE, AND IS NOT ANY MORE ──────
            //
            // My Posts, Saved and Service History were three rows in this
            // screen. They are the Activity TAB now, the first two as its two
            // scopes, the third as its header action, so leaving them here
            // would be a second path to the same three places, one tap deeper,
            // in a screen that is supposed to be about the account.
            //
            // This is what makes Activity a RELOCATION rather than an
            // addition: Profile got shorter by exactly what the new tab
            // absorbed.
            //
            if (businessRows.isNotEmpty)
              _SettingsSection(title: 'Business', children: businessRows),
            // ── Account ─────────────────────────────────────────────────
            _SettingsSection(
              title: 'Account',
              children: [
                // No meter here any more: how complete the profile is counts
                // as a step in "Get ready to work". This row is just the
                // way to edit it.
                _SettingsTile(
                  icon: AppIcons.account,
                  title: 'Professional profile',
                  trailing: const Icon(AppIcons.disclosure),
                  onTap: () => _openSetupStep(SetupStep.completeProfile, profile),
                ),
                // Every way into this account (Google, email, phone) and a way
                // to add the ones it lacks, linked onto this account, never a
                // second one. See SignInMethodsScreen.
                _SettingsTile(
                  icon: AppIcons.locked,
                  title: 'Sign-in methods',
                  value: '${AuthService.signInMethods.length} added',
                  trailing: const Icon(AppIcons.disclosure),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SignInMethodsScreen()),
                  ).then((_) {
                    if (mounted) setState(() {});
                  }),
                ),
                // Agent credit (migration 127): add or correct the code of the
                // agent who signed this member up, only in their first 3 days.
                if (_agentCodesOpen)
                  _SettingsTile(
                  icon: AppIcons.person,
                  title: 'Who helped you join?',
                  trailing: const Icon(AppIcons.disclosure),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AgentCodeScreen()),
                  ),
                ),
                // ONE PLACE FOR MONEY. "Payment number" (the number you pay
                // from) and "Payout destinations" (where earnings go) were two
                // rows in two sections that read as the same thing. They are
                // two parts of one screen now. See _PaymentsScreen and
                // payout_authority.dart (§M4) for what each part may claim.
                _SettingsTile(
                  icon: AppIcons.paymentNumber,
                  title: 'Payments',
                  value: (profile?.phone?.isNotEmpty == true) ? null : 'Not set',
                  trailing: const Icon(AppIcons.disclosure),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => _PaymentsScreen(uid: widget.uid)),
                  ).then((_) {
                    // A payout number added there is a setup step done here.
                    if (mounted) _loadSetup();
                  }),
                ),
                // Account status is not a row any more. It is
                // _AccountStandingBanner at the top, shown only when the
                // standing is not good, so the way to read or appeal a
                // restriction is still never hidden behind it.
              ],
            ),
          ],
        );
      },
    );
  }

  /// Opens one setup step. Shared by the "Get ready to work" row and the
  /// Business rows, so both always land on the same screen.
  Future<void> _openSetupStep(SetupStep step, UserModel? profile) async {
    final route = switch (step) {
      SetupStep.completeProfile => MaterialPageRoute<bool>(
          builder: (_) => ProfessionalProfileScreen(
            uid: widget.uid,
            initialProfile: profile,
            emailFromAuth: widget.authUser.email ?? '',
            phoneFromAuth: widget.authUser.phoneNumber,
          ),
        ),
      SetupStep.offerServices => MaterialPageRoute<bool>(
          builder: (_) => ProviderOnboardingScreen(
            uid: widget.uid,
            initialProfile: profile,
            emailFromAuth: widget.authUser.email ?? '',
            phoneFromAuth: widget.authUser.phoneNumber,
          ),
        ),
      SetupStep.verifyIdentity => MaterialPageRoute<bool>(
          builder: (_) => VerificationScreen(uid: widget.uid),
        ),
      SetupStep.addPayout => MaterialPageRoute<bool>(
          builder: (_) => PayoutDestinationsScreen(uid: widget.uid),
        ),
    };
    final changed = await Navigator.push<bool>(context, route);
    if (!mounted) return;
    // Any step can change what the setup row counts, so it re-reads on
    // return; the profile steps also change the profile row itself.
    _loadSetup();
    if (changed == true) _resubscribe();
  }
}

// _MyPostsTile removed with the "My Activity" section above. It fetched its
// own live post count on a screen that no longer lists posts; the Activity tab
// shows the posts themselves.

/// Profile identity hero for logged in users (users row, auth fallback).
class _LoggedInProfile extends StatelessWidget {
  final UserModel? profile;
  final dynamic authUser; // AppUser

  const _LoggedInProfile({this.profile, required this.authUser});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final profession = profile?.profession.trim() ?? '';
    final bio = profile?.bio.trim() ?? '';
    final name = profile?.displayName ?? authUser.displayName;
    final email = profile?.email ?? authUser.email;
    final secondary = email.isNotEmpty ? email : (authUser.phoneNumber ?? '');
    final avatarUrl = (profile?.profileImage != null && profile!.profileImage.isNotEmpty)
        ? profile!.profileImage
        : (authUser.photoUrl != null && authUser.photoUrl.isNotEmpty ? authUser.photoUrl : '');
    final initials = profile?.initials ?? authUser.initials;

    return Column(
      children: [
        // A PHOTO OF A PERSON NEEDS NO DECORATION.
        //
        // This was a two-stop gradient with a coloured drop shadow behind it,
        // the most "generated" element in the app, and it glowed indigo behind
        // a real photograph. The ring is now a hairline, and initials sit on a
        // neutral surface.
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            color: AppColors.of(context).surfaceSunken,
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.of(context).borderHairline),
          ),
          child: Center(
            child: avatarUrl.isNotEmpty
                ? ClipRRect(
                    borderRadius: AppRadius.pillAll,
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
                        AppIcons.person,
                        size: 44,
                        color: Colors.white70,
                      ),
                    ),
                  )
                : Text(
                    initials,
                    style: TextStyle(
                      color: AppColors.of(context).contentSecondary,
                      fontSize: 34,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: AppSpace.lg),

        Text(
          name,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          secondary,
          style: AppTypeScale.bodyM.copyWith(
            fontFamily: AppTypeScale.family,
            color: c.contentSecondary,
          ),
        ),

        // TITLE AND BIO COME FROM ONE ROW.
        //
        // Both are read from the same users row ([profile]) and nothing else:
        // the title is `profession` through the registry (a stored slug shows
        // its label, legacy free text shows as typed), the bio is `bio`. There
        // are no fallbacks or defaults, so if they disagree it is because the
        // member wrote them that way, and editing either one on the
        // Professional profile fixes it here. An empty bio shows nothing.
        if (profession.isNotEmpty) ...[
          const SizedBox(height: AppSpace.md),
          ProfessionChip(profession: profession, fontSize: 12.5),
        ],
        if (bio.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            bio,
            style: AppTypeScale.bodyM.copyWith(
              fontFamily: AppTypeScale.family,
              color: c.contentSecondary,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
        // Member since is gone, and the reputation card with it. The stats
        // live in _ProfileStats, shown only after a completed job.
      ],
    );
  }
}

/// "Get ready to work": how many setup steps are done, as "1 of 3" and a
/// thin bar. Tapping opens the first step that is not done. The parent only
/// builds it while setup is known and incomplete.
class _ProfileSetupRow extends StatelessWidget {
  final ProfileSetup setup;
  final VoidCallback onTap;

  const _ProfileSetupRow({required this.setup, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.sm),
      child: Material(
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
          side: BorderSide(color: c.borderHairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Get ready to work',
                        style: AppTypeScale.bodyL.copyWith(
                          fontFamily: AppTypeScale.family,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: c.contentPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${setup.completed} of ${setup.total}',
                      style: AppTypeScale.bodyS.copyWith(
                        fontFamily: AppTypeScale.family,
                        color: c.contentTertiary,
                      ),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Icon(Icons.chevron_right_rounded, size: 20, color: c.contentTertiary),
                  ],
                ),
                const SizedBox(height: AppSpace.md),
                ClipRRect(
                  borderRadius: AppRadius.pillAll,
                  child: LinearProgressIndicator(
                    value: setup.fraction,
                    minHeight: 4,
                    backgroundColor: c.surfaceSunken,
                    valueColor: AlwaysStoppedAnimation<Color>(c.accentFill),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The member's record, as one flat row: Jobs and Rating. Nothing at all
/// until there is a completed job, so a new member never sees a row of zeros.
class _ProfileStats extends StatefulWidget {
  final String uid;
  const _ProfileStats({required this.uid});

  @override
  State<_ProfileStats> createState() => _ProfileStatsState();
}

class _ProfileStatsState extends State<_ProfileStats> {
  late Future<ReputationResult> _future;
  late ReputationResult _seed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _ProfileStats oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) _load();
  }

  void _load() {
    _seed = ReputationService.peek(widget.uid);
    _future = ReputationService.getResult(widget.uid);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReputationResult>(
      future: _future,
      initialData: _seed.hasValue ? _seed : null,
      builder: (context, snap) {
        final rep = snap.data?.rep;
        if (rep == null || rep.completedJobs <= 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: AppSpace.lg),
          child: Row(
            children: [
              Expanded(child: _Stat(value: '${rep.completedJobs}', label: 'Jobs')),
              Expanded(
                child: _Stat(
                  value: rep.hasReviews ? rep.averageRating.toStringAsFixed(1) : 'None',
                  label: 'Rating',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  final String value;
  final String label;
  const _Stat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Column(
      children: [
        Text(
          value,
          style: AppTypeScale.headingM.copyWith(
            fontFamily: AppTypeScale.family,
            color: c.contentPrimary,
          ),
        ),
        Text(
          label,
          style: AppTypeScale.meta.copyWith(
            fontFamily: AppTypeScale.family,
            color: c.contentTertiary,
          ),
        ),
      ],
    );
  }
}

/// Shown at the top of Profile only when the account is restricted,
/// suspended or banned: one line and one button. A good standing shows
/// nothing, and so does a standing that has not loaded.
class _AccountStandingBanner extends StatelessWidget {
  const _AccountStandingBanner();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AccountStatusStore.instance,
      builder: (context, _) {
        final c = AppColors.of(context);
        final (String? message, Color fg, Color bg) =
            switch (AccountStatusStore.instance.status.standing) {
          AccountStanding.restricted => ('Your account is restricted', c.cautionText, c.cautionSubtle),
          AccountStanding.suspended => ('Your account is suspended', c.criticalText, c.criticalSubtle),
          AccountStanding.banned => ('Your account is banned', c.criticalText, c.criticalSubtle),
          AccountStanding.active || AccountStanding.unknown => (null, c.contentPrimary, c.surface),
        };
        if (message == null) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: AppSpace.lg),
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.sm, AppSpace.sm),
          decoration: BoxDecoration(color: bg, borderRadius: AppRadius.lgAll),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  style: AppTypeScale.bodyM.copyWith(
                    fontFamily: AppTypeScale.family,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AccountStatusScreen()),
                ),
                style: TextButton.styleFrom(foregroundColor: fg),
                child: const Text('See details'),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The one action in the footer (Sign out, or Sign in): text alone, centred.
///
/// THE BUTTON IS THE WORD, NOT THE LINE. This was a full-width button, so a
/// press anywhere along the line lit up a red strip across the screen: the
/// behaviour of a list row on something styled as a text action. Now the tap
/// target and the press highlight hug the label (48 px tall, 16 px either
/// side), the way text actions behave in platform settings screens.
class _FooterAction extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _FooterAction({required this.label, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: color,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
        ),
        child: Text(
          label,
          style: AppTypeScale.bodyL.copyWith(
            fontFamily: AppTypeScale.family,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// A small muted link in the footer (Terms, Privacy).
class _FooterLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _FooterLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.smAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: AppSpace.sm),
        child: Text(
          label,
          style: AppTypeScale.meta.copyWith(
            fontFamily: AppTypeScale.family,
            color: c.contentTertiary,
          ),
        ),
      ),
    );
  }
}

/// PAYMENTS: the number you pay from, and where your earnings go.
///
/// These were two rows in two sections ("Payment number" under Account,
/// "Payout destinations" under Business) that members read as one thing.
/// They are one screen now (payout_authority.dart, §M4).
///
/// "You get paid to" appears ONLY once the server confirms payout numbers are
/// live. It used to render a row while the check was in flight and then swap
/// it for a note once the answer came back ("payouts are off"), so the
/// section flickered and changed under the member's thumb. With payout
/// numbers off, earnings settle to the payment number and the payment sheet's
/// own note already says so; offline or on error, nothing is claimed.
class _PaymentsScreen extends StatefulWidget {
  final String uid;
  const _PaymentsScreen({required this.uid});

  @override
  State<_PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<_PaymentsScreen> {
  late Stream<UserModel?> _stream = UserProfileService.watchUser(widget.uid);
  PayoutAuthority _authority = PayoutAuthority.unknown;
  PayoutDestination? _payout;

  @override
  void initState() {
    super.initState();
    _loadPayout();
  }

  Future<void> _loadPayout() async {
    var reachable = true;
    var unavailable = false;
    PayoutDestination? payout;
    try {
      final active = (await PayoutService.listDestinations(widget.uid))
          .where((d) => d.status == PayoutDestinationStatus.active)
          .toList();
      payout = active.where((d) => d.isDefault).firstOrNull ?? active.firstOrNull;
    } on PayoutException catch (e) {
      if (e.featureUnavailable) {
        unavailable = true;
      } else {
        reachable = false;
      }
    } catch (_) {
      reachable = false;
    }
    if (!mounted) return;
    setState(() {
      _authority = resolvePayoutAuthority(
        reachable: reachable,
        featureUnavailable: unavailable,
      );
      _payout = payout;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Payments')),
      body: StreamBuilder<UserModel?>(
        stream: _stream,
        builder: (context, snap) {
          final phone = snap.data?.phone;
          final hasPhone = phone != null && phone.isNotEmpty;
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpace.gutter, 0, AppSpace.gutter, AppSpace.xl),
            children: [
              _SettingsSection(
                title: 'You pay from',
                children: [
                  // The number is sensitive: masked here, revealed only
                  // behind the biometric gate in the sheet.
                  _SettingsTile(
                    icon: AppIcons.paymentNumber,
                    title: 'Payment number',
                    value: hasPhone ? maskPhone(phone) : 'Not set',
                    trailing: const Icon(AppIcons.disclosure),
                    onTap: () => showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => _PaymentSettingsSheet(
                        uid: widget.uid,
                        currentPhone: phone,
                      ),
                    ).then((_) {
                      if (mounted) {
                        setState(() => _stream = UserProfileService.watchUser(widget.uid));
                      }
                    }),
                  ),
                ],
              ),
              if (_authority == PayoutAuthority.destinations)
                _SettingsSection(
                  title: 'You get paid to',
                  children: [
                    _SettingsTile(
                      icon: AppIcons.payoutDestination,
                      title: 'Payout number',
                      value: _payout != null ? maskPhone(_payout!.destination) : 'Not set',
                      trailing: const Icon(AppIcons.disclosure),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PayoutDestinationsScreen(uid: widget.uid),
                        ),
                      ).then((_) {
                        if (mounted) _loadPayout();
                      }),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
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
            borderRadius: AppRadius.pillAll,
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              width: 2,
            ),
          ),
          child: Center(
            child: Icon(
              AppIcons.person,
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
        // "Sign in to access all features" is true of every app ever written
        // and says nothing about this one. Browsing already works without an
        // account, what an account actually buys is naming the three things
        // it unlocks, which is also what makes the ask feel proportionate.
        Text(
          'Sign in to post a job, apply for work and message people.',
          textAlign: TextAlign.center,
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
            icon: const Icon(AppIcons.signIn),
            label: const Text('Sign in'),
          ),
        ),
      ],
    );
  }
}

/// Trailing affordance for Support rows that open the Help24 website in an
/// in-app browser tab, signals the row leaves the app for the web.
class _ExternalTrailing extends StatelessWidget {
  const _ExternalTrailing();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Icon(
      AppIcons.externalLink,
      size: 18,
      color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    // SectionHeader owns the gap above AND below, which is what [_gapAbove]
    // was invented for here. AppRowGroup owns the surface and its outline;
    // the rows are separated by whitespace, never by a line.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title),
        AppRowGroup(children: children),
      ],
    );
  }
}

/// A row in a Profile group.
///
/// ── There is no `subtitle` any more. There is a `value`. ────────────────
/// The parameter was renamed deliberately, so the type system is what stops a
/// description coming back. A `subtitle` invites an explanation of where the
/// row goes, and NINE shipped in a row on this screen:
///
///   Become a Provider  / "Profession, contact & verified payout number"
///   Payout Destinations/ "Where your M-Pesa earnings are sent"
///   Saved              / "Your shortlist of posts & providers"
///   Service History    / "Completed services, work & receipts"
///   Promote Business   / "Feature a listing, campaigns, results & payments"
///   Notifications      / "Sign in"      ← which is what tapping it does
///   Location Access    / "Sign in"
///   Professional Profile / "Sign in to build your profile"
///
/// A `value` is right-aligned and can only carry STATE the user cannot
/// otherwise see: `14 active`, `Device Default`, `English`, `Off`. If a row has
/// no state worth showing it shows nothing, and the destination explains itself
/// the moment it opens, which it can, because it is a whole screen.
class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;

  /// Current state. Never a description of the destination.
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.value,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppRow(
      icon: icon,
      title: title,
      value: value,
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// One row of the Theme sheet.
class _ThemeOptionTile extends StatelessWidget {
  final ThemePreference option;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeOptionTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.lgAll,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primaryAccent.withValues(alpha: 0.08)
                : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
            borderRadius: AppRadius.lgAll,
            border: Border.all(
              color: selected ? AppTheme.primaryAccent.withValues(alpha: 0.45) : border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                option.icon,
                size: 22,
                color: selected
                    ? AppTheme.primaryAccent
                    : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(option.label, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(option.description, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              if (selected)
                const Icon(AppIcons.successFilled,
                    color: AppTheme.primaryAccent, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Notification toggle ──────────────────────────────────────────────────────
class _NotificationSwitchTile extends StatefulWidget {
  final String uid;
  const _NotificationSwitchTile({required this.uid});
  @override
  State<_NotificationSwitchTile> createState() => _NotificationSwitchTileState();
}

/// One tap, one transition.
///
/// The switch reads exactly one value, [NotificationToggleState.displayed],
/// and that value moves only when the user chooses, when a write resolves, or
/// when a fresh read arrives. See `notification_toggle_state.dart` for the
/// device trace of the three-transition flicker this replaced.
class _NotificationSwitchTileState extends State<_NotificationSwitchTile> {
  /// ONE subscription for the life of the tile.
  ///
  /// `watchUserPrefs()` used to be called inside `build()`, so every rebuild,
  /// including the one the user's own tap causes, spun up a new controller and
  /// an `AdaptivePoll` that immediately fired a read. That read overlapped the
  /// write and came back with the pre-write value, which is what the switch
  /// then snapped to.
  StreamSubscription<({bool notificationsEnabled, String language})>? _prefsSub;

  NotificationToggleState _toggle = const NotificationToggleState();

  /// The OS's answer, not Firebase's, false means Android has Help24's
  /// notifications switched off and only the user can switch them back on.
  bool _osBlocked = false;

  @override
  void initState() {
    super.initState();
    _listenToPrefs();
    _refreshOsState();
  }

  @override
  void didUpdateWidget(covariant _NotificationSwitchTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uid != widget.uid) {
      // A different account: nothing is known about it yet, and the previous
      // account's preference must not be shown for it.
      setState(() => _toggle = const NotificationToggleState());
      _listenToPrefs();
    }
  }

  @override
  void dispose() {
    _prefsSub?.cancel();
    super.dispose();
  }

  void _listenToPrefs() {
    _prefsSub?.cancel();
    _prefsSub = UserProfileService.watchUserPrefs(widget.uid).listen((prefs) {
      if (!mounted) return;
      final next = _toggle.storedValueRead(prefs.notificationsEnabled);
      // The poll re-reads every 15s and almost always reports what is already
      // on screen. Rebuilding the switch for an answer that changes nothing is
      // work the control does not need.
      if (next == _toggle) return;
      setState(() => _toggle = next);
    });
  }

  Future<void> _refreshOsState() async {
    final capability = await NotificationService.capability();
    if (!mounted) return;
    final blocked = capability == NotificationCapability.osBlocked;
    if (blocked == _osBlocked) return; // No change, no rebuild.
    setState(() => _osBlocked = blocked);
  }

  void _nudgeToSystemSettings() {
    ActionFeedback.info(
      context,
      "Notifications for Help24 are turned off in your phone's settings.",
      actionLabel: 'Open settings',
      onAction: NotificationService.openSystemNotificationSettings,
    );
  }

  Future<void> _onChanged(bool value) async {
    setState(() => _toggle = _toggle.userChose(value));
    try {
      if (value) {
        final capability =
            await NotificationService.enableAndSaveToken(widget.uid);
        if (!mounted) return;
        setState(() => _toggle = _toggle.writeSucceeded(true));
        if (capability == NotificationCapability.osBlocked) {
          _nudgeToSystemSettings();
        }
      } else {
        await NotificationService.disableAndRemoveToken(widget.uid);
        if (!mounted) return;
        setState(() => _toggle = _toggle.writeSucceeded(false));
      }
      await _refreshOsState();
    } catch (e) {
      // Nothing was saved, so the switch returns to what IS saved and says why
      //, a silent revert reads as the control being broken.
      if (!mounted) return;
      setState(() => _toggle = _toggle.writeFailed(value));
      ActionFeedback.failure(context, e, context_: ErrorContext.save);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _SettingsTile(
      icon: AppIcons.notifications,
      title: l10n?.t('notifications') ?? 'Notifications',
      value: _osBlocked ? "Blocked in phone settings" : null,
      // The whole row toggles, so the switch can drop its extra touch padding
      // (which made this row taller than its neighbours) without shrinking
      // the target: the target is the 52 px row.
      onTap: _osBlocked
          ? _nudgeToSystemSettings
          : () => _onChanged(!_toggle.displayed),
      trailing: Switch.adaptive(
        value: _toggle.displayed && !_osBlocked,
        onChanged: _onChanged,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
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

  /// Starts `unknown` so the sheet says NOTHING about payouts until the probe
  /// answers. A wrong claim here either strands earnings or invites a provider
  /// to configure a number the backend will ignore.
  PayoutAuthority _authority = PayoutAuthority.unknown;

  @override
  void initState() {
    super.initState();
    _phoneController = TextEditingController(text: widget.currentPhone ?? '');
    // Skip biometric gate when no number has been set yet
    _unlocked = widget.currentPhone == null || widget.currentPhone!.isEmpty;
    _resolveAuthority();
  }

  /// Ask the same production signal the rest of the app uses:
  /// `/payout-destinations` answers 503 while the feature flag is off.
  Future<void> _resolveAuthority() async {
    PayoutAuthority resolved;
    try {
      await PayoutService.listDestinations(widget.uid);
      resolved = resolvePayoutAuthority(reachable: true, featureUnavailable: false);
    } on PayoutException catch (e) {
      // Only the documented 503 proves "flag off". Any other non-2xx (401,
      // 429, 500) proves nothing about the flag, so it stays `unknown`.
      resolved = resolvePayoutAuthority(
        reachable: e.featureUnavailable,
        featureUnavailable: e.featureUnavailable,
      );
    } catch (_) {
      resolved = resolvePayoutAuthority(reachable: false, featureUnavailable: false);
    }
    if (mounted) setState(() => _authority = resolved);
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
        // Device has no lock screen, skip gate
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
    } on PlatformException catch (e) {
      // The plugin's own prose ("local_auth plugin requires a foreground
      // activity", "No Biometrics enrolled on this device.") is for
      // developers; its code says what the person can actually do.
      debugPrint('[AUTH][Profile] device auth failed: ${e.code} ${e.message}');
      if (mounted) {
        setState(() {
          _authenticating = false;
          _error = _deviceAuthMessage(e.code);
        });
      }
    } on Exception catch (e) {
      debugPrint('[Profile] biometric auth failed: $e');
      if (mounted) {
        setState(() {
          _authenticating = false;
          _error = ErrorMapper.toMessage(e, context: ErrorContext.auth);
        });
      }
    }
  }

  /// What to do next, by the device-auth failure code. A lockout needs
  /// waiting, not retrying, "please try again" was wrong advice for it.
  static String _deviceAuthMessage(String code) => switch (code) {
        auth_error.lockedOut =>
          'Too many attempts. Wait 30 seconds, then try again.',
        auth_error.permanentlyLockedOut =>
          'Too many attempts. Unlock your phone with your PIN or pattern, then try again.',
        auth_error.notAvailable ||
        auth_error.notEnrolled ||
        auth_error.passcodeNotSet =>
          'Set up a screen lock on your phone to change your M-Pesa number.',
        _ => "We couldn't verify it's you. Please try again.",
      };

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
            shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
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
        const SheetHandle(margin: EdgeInsets.only(bottom: 20)),
        Row(
          children: [
            const IconBadge(AppIcons.device, color: AppTheme.primaryAccent),
            const SizedBox(width: 12),
            Text('Payment number', style: Theme.of(context).textTheme.titleLarge),
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
          borderRadius: AppRadius.sheetTop,
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
            borderRadius: AppRadius.mdAll,
            border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ),
          child: Row(
            children: [
              Icon(AppIcons.device, size: 20,
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
              Icon(AppIcons.locked, size: 18,
                  color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
            ],
          ),
        ),
        _PayoutAuthorityNote(authority: _authority, uid: widget.uid),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _authenticating ? null : _authenticate,
            icon: _authenticating
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(AppIcons.biometric, size: 18),
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
            borderRadius: AppRadius.mdAll,
            border: Border.all(color: AppTheme.primaryAccent.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Icon(AppIcons.info, size: 18, color: AppTheme.primaryAccent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'The M-Pesa number you pay from, and how clients reach you.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.primaryAccent),
                ),
              ),
            ],
          ),
        ),
        // The payout claim is never hard-coded: it tracks the live backend
        // flag, and stays silent when the probe could not answer (§M4).
        _PayoutAuthorityNote(authority: _authority, uid: widget.uid),
        const SizedBox(height: 20),
        TextField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'M-Pesa Number',
            hintText: '254XXXXXXXXX',
            prefixIcon: const Icon(AppIcons.device),
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

/// The one place the legacy number is allowed to mention payouts.
///
/// Renders nothing at all for [PayoutAuthority.unknown], silence is the
/// correct output when the probe could not answer, per the state-truthfulness
/// contract. When Payout Destinations is live it both disclaims payout
/// authority AND routes there, so the sheet can never be a dead end that
/// leaves a provider believing this number pays them.
class _PayoutAuthorityNote extends StatelessWidget {
  final PayoutAuthority authority;
  final String uid;

  const _PayoutAuthorityNote({required this.authority, required this.uid});

  @override
  Widget build(BuildContext context) {
    final note = payoutNoteFor(authority);
    if (note == null) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDisclaimer = authority == PayoutAuthority.destinations;
    final accent = isDisclaimer ? AppTheme.warningOrange : AppTheme.primaryAccent;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: AppRadius.mdAll,
          border: Border.all(color: accent.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isDisclaimer ? AppIcons.warning : AppIcons.info,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    note,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary,
                        ),
                  ),
                ),
              ],
            ),
            if (isDisclaimer) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () {
                    // Capture before popping, this context belongs to the
                    // sheet and is defunct the moment it closes.
                    final navigator = Navigator.of(context);
                    navigator.pop();
                    navigator.push<void>(
                      MaterialPageRoute(
                        builder: (_) => PayoutDestinationsScreen(uid: uid),
                      ),
                    );
                  },
                  icon: const Icon(AppIcons.payoutDestination, size: 16),
                  label: const Text('Open payout destinations'),
                ),
              ),
            ],
          ],
        ),
      ),
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

  /// Whether [_feedback] reports success. Explicit: the colour used to be
  /// chosen by `_feedback.contains('updated')`, so a failure sentence that
  /// ever contained that word would have been painted as a success.
  bool _feedbackOk = false;

  /// The outcome [_feedback] describes, and whether the device was offline
  /// then, kept so the message is dropped the moment it stops being true.
  /// Without it the header flipped to "Location Enabled" the instant location
  /// came back on, while "Turn on location services and try again." stayed
  /// underneath until the next refresh (seen on a device).
  CurrentLocationResult? _lastResult;
  bool _lastOffline = false;

  // Captured in initState rather than read in dispose(): the element is
  // defunct by then (test/dispose_safety_test.dart).
  late final LocationProvider _location;
  late final ConnectivityProvider _connectivity;

  @override
  void initState() {
    super.initState();
    _location = context.read<LocationProvider>();
    _connectivity = context.read<ConnectivityProvider>();
    _location.addListener(_dropStaleFeedback);
    _connectivity.addListener(_dropStaleFeedback);
  }

  @override
  void dispose() {
    _location.removeListener(_dropStaleFeedback);
    _connectivity.removeListener(_dropStaleFeedback);
    super.dispose();
  }

  /// Clear the message once what it said no longer holds, location turned
  /// back on, permission granted, the connection restored. See
  /// CurrentLocationResult.stillApplies.
  void _dropStaleFeedback() {
    if (!mounted || _refreshing || _feedback == null) return;
    final result = _lastResult;
    final stillTrue = result != null
        ? result.stillApplies(
            locationOn: _location.isLocationOn,
            serviceEnabled: _location.serviceEnabled,
            permissionGranted: _location.isGranted,
            offlineNow: _connectivity.isOffline,
            wasOffline: _lastOffline,
          )
        // A thrown error: only a connection problem has a resolution the
        // app can see happen.
        : !(_lastOffline && !_connectivity.isOffline);
    if (stillTrue) return;
    setState(() {
      _feedback = null;
      _lastResult = null;
    });
  }

  Future<void> _refreshLocation() async {
    setState(() {
      _refreshing = true;
      _feedback = null;
      _lastResult = null;
    });
    try {
      final result = await _location.captureCurrentLocation(widget.userId);
      if (!mounted) return;
      final ok = result.isSuccess;
      final offline = _connectivity.isOffline;
      setState(() {
        // Why it failed, not one sentence for every cause, see
        // CurrentLocationResult.refreshMessage.
        _feedback = ok ? 'Location updated.' : result.refreshMessage(offline: offline);
        _feedbackOk = ok;
        _lastResult = result;
        _lastOffline = offline;
      });
      if (ok) {
        // New coordinates → the distance signal has something better to work
        // with, so the feed is re-ranked from where the user actually is.
        final location = context.read<LocationProvider>();
        context.read<AppProvider>().setViewer(
              userId: widget.userId,
              latitude: location.latitude,
              longitude: location.longitude,
            );
      }
    } catch (e) {
      // Expected failures arrive as a result above. A platform channel
      // throwing is the unexpected one, it used to escape this method with
      // no message at all; now it is mapped, never shown raw.
      if (mounted) {
        setState(() {
          _feedback = ErrorMapper.toMessage(e, context: ErrorContext.location);
          _feedbackOk = false;
          _lastResult = null;
          _lastOffline = ErrorMapper.isConnectivityError(e);
        });
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
      // Location disabled in-app: drop the coordinates so ranking stops using
      // them. The distance signal then reports "not applicable" and its weight
      // leaves the calculation entirely, the feed re-ranks on everything else
      // rather than scoring every post as though it were nowhere.
      context.read<AppProvider>().setViewer(
            userId: widget.userId,
            latitude: null,
            longitude: null,
          );
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
        // Header reflects the real state live: green only when location is truly
        // on (permission + OS service + a stored location). It flips to amber the
        // instant the OS toggle is switched off OR the user disables in-app, with
        // copy that names the actual reason and the way back.
        final on = location.isLocationOn;
        final serviceOff = !location.serviceEnabled;
        final headerColor = on ? AppTheme.successGreen : AppTheme.warningOrange;
        final headerTitle = on ? 'Location Enabled' : 'Location is off';
        final headerSubtitle = on
            ? 'Location access is active'
            : serviceOff
                ? 'Turn on location in your device settings'
                : 'Tap Refresh Location to turn it back on';

        return Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: AppRadius.sheetTop,
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
              const SheetHandle(margin: EdgeInsets.zero),
              const SizedBox(height: 20),

              // Header row
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: headerColor.withValues(alpha: 0.12),
                      borderRadius: AppRadius.mdAll,
                    ),
                    child: Icon(
                      on ? AppIcons.location : AppIcons.locationOff,
                      color: headerColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headerTitle,
                        style: TextStyle(
                          color: textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        headerSubtitle,
                        style: TextStyle(color: headerColor, fontSize: 12),
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
                  borderRadius: AppRadius.mdAll,
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DetailRow(
                      icon: AppIcons.location,
                      label: 'Current location',
                      value: (city != null && city.isNotEmpty)
                          ? city
                          : 'Not yet detected',
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                    ),
                    const SizedBox(height: 10),
                    _DetailRow(
                      icon: AppIcons.pending,
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
                    color: _feedbackOk ? AppTheme.successGreen : AppTheme.warningOrange,
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
                      : const Icon(AppIcons.currentLocation, size: 18),
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
                      : const Icon(AppIcons.locationOff, size: 18),
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

/// Labels are sentence case ("Help centre", "Terms of service").
///
/// The en.json bundled in the 1.0.11 APK still says "Help Centre" and
/// "Terms of Service", and a Shorebird patch cannot change bundled files, so
/// patched phones would mix the two styles on one screen. Applying the case
/// here makes the label right whichever en.json the phone has. Safe for these
/// four labels because none of them holds a proper noun.
String _sentenceCase(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
