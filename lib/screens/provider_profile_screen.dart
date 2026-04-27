import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/post_model.dart';
import '../providers/auth_provider.dart';
import '../services/chat_service_supabase.dart';
import '../theme/app_theme.dart';
import '../widgets/auth_guard.dart';
import 'messages_screen.dart';

class ProviderProfileScreen extends StatefulWidget {
  final String providerId;

  const ProviderProfileScreen({super.key, required this.providerId});

  @override
  State<ProviderProfileScreen> createState() => _ProviderProfileScreenState();
}

class _ProviderProfileScreenState extends State<ProviderProfileScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _provider;
  String? _linkedUserId;
  String? _linkedUserAvatar;
  int _postCount = 0;
  int _jobsCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final client = Supabase.instance.client;

      final providerData = await client
          .from('providers')
          .select('*')
          .eq('id', widget.providerId)
          .single();

      String? linkedUserId;
      String? linkedUserAvatar;
      int postCount = 0;
      int jobsCount = 0;

      final phoneLogin = providerData['phone_login'] as String?;
      if (phoneLogin != null && phoneLogin.isNotEmpty) {
        try {
          final userRow = await client
              .from('users')
              .select('id, profile_image, avatar_url')
              .eq('phone_number', phoneLogin)
              .maybeSingle();

          if (userRow != null) {
            linkedUserId = userRow['id'] as String?;
            final img = (userRow['profile_image'] as String?)?.trim();
            final av = (userRow['avatar_url'] as String?)?.trim();
            linkedUserAvatar =
                (img != null && img.isNotEmpty) ? img : (av?.isNotEmpty == true ? av : null);

            if (linkedUserId != null && linkedUserId.isNotEmpty) {
              final posts = await client
                  .from('posts')
                  .select('id')
                  .eq('author_user_id', linkedUserId);
              postCount = (posts as List).length;

              final apps = await client
                  .from('applications')
                  .select('id')
                  .eq('applicant_user_id', linkedUserId);
              jobsCount = (apps as List).length;
            }
          }
        } catch (_) {
          // Stats are supplemental — safe to swallow
        }
      }

      if (!mounted) return;
      setState(() {
        _provider = Map<String, dynamic>.from(providerData as Map);
        _linkedUserId = linkedUserId;
        _linkedUserAvatar = linkedUserAvatar;
        _postCount = postCount;
        _jobsCount = jobsCount;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load provider profile. Please check your connection and try again.';
        _loading = false;
      });
    }
  }

  Future<void> _onMessageTap(BuildContext context) async {
    final currentUserId = context.read<AuthProvider>().currentUserId ?? '';
    if (currentUserId.isEmpty) return;

    if (_linkedUserId == null || _linkedUserId!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This provider is not yet on the messaging platform.'),
          backgroundColor: AppTheme.warningOrange,
        ),
      );
      return;
    }

    if (_linkedUserId == currentUserId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This is your own provider profile.')),
      );
      return;
    }

    try {
      final conversation = await ChatServiceSupabase.createChat(
        user1Id: currentUserId,
        user2Id: _linkedUserId!,
        currentUserId: currentUserId,
      );
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            conversation: conversation,
            currentUserId: currentUserId,
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open chat: $e'),
          backgroundColor: AppTheme.errorRed,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Scaffold(
      backgroundColor: bg,
      body: _loading
          ? _buildLoading(isDark, textPrimary)
          : _error != null || _provider == null
              ? _buildError(isDark, textPrimary)
              : _buildProfile(isDark),
    );
  }

  Widget _buildLoading(bool isDark, Color textPrimary) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _AppBarSliver(isDark: isDark, title: ''),
        ),
        const Center(
          child: CircularProgressIndicator(
            color: AppTheme.primaryAccent,
            strokeWidth: 2.5,
          ),
        ),
      ],
    );
  }

  Widget _buildError(bool isDark, Color textPrimary) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _AppBarSliver(isDark: isDark, title: ''),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppTheme.errorRed.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person_off_outlined,
                      size: 40, color: AppTheme.errorRed),
                ),
                const SizedBox(height: 20),
                Text(
                  'Profile Unavailable',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _error ?? 'Provider not found.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh,
                      size: 16, color: AppTheme.primaryAccent),
                  label: const Text(
                    'Try Again',
                    style: TextStyle(color: AppTheme.primaryAccent),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProfile(bool isDark) {
    final provider = _provider!;
    final name = (provider['name'] as String?)?.trim() ?? 'Unknown Provider';
    final location = (provider['location'] as String?)?.trim() ?? '';
    final rawServices = provider['services'];
    final List<String> services = rawServices is List
        ? rawServices.map((s) => s.toString()).where((s) => s.isNotEmpty).toList()
        : (rawServices?.toString().isNotEmpty == true
            ? [rawServices.toString()]
            : []);
    final phoneLogin = provider['phone_login'] as String?;
    final phonePayout = provider['phone_payout'] as String?;
    final createdAt = provider['created_at'] != null
        ? DateTime.tryParse(provider['created_at'].toString())
        : null;

    final initials = name.trim().split(RegExp(r'\s+')).take(2).map((w) {
      return w.isEmpty ? '' : w[0].toUpperCase();
    }).join();

    final bool phoneVerified = phoneLogin != null && phoneLogin.isNotEmpty;
    final bool paymentSetup = phonePayout != null && phonePayout.isNotEmpty;

    final cardBg = isDark ? AppTheme.darkCard : AppTheme.lightCard;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Stack(
      children: [
        // ── Scrollable body ──────────────────────────────────────────────────
        CustomScrollView(
          slivers: [
            // App bar
            SliverAppBar(
              pinned: true,
              backgroundColor:
                  isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
              elevation: 0,
              leading: IconButton(
                icon: Icon(Icons.arrow_back_ios_new_rounded,
                    size: 20, color: textPrimary),
                onPressed: () => Navigator.pop(context),
              ),
              title: Text(
                name,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              centerTitle: true,
            ),

            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(20, 8, 20, 100), // 100 for CTA
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Hero ────────────────────────────────────────────────
                    _buildHero(
                      name: name,
                      initials: initials,
                      location: location,
                      createdAt: createdAt,
                      cardBg: cardBg,
                      borderColor: borderColor,
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 16),

                    // ── Stats row ────────────────────────────────────────────
                    _buildStatsRow(
                      postCount: _postCount,
                      jobsCount: _jobsCount,
                      createdAt: createdAt,
                      cardBg: cardBg,
                      borderColor: borderColor,
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                    ),
                    const SizedBox(height: 16),

                    // ── Trust badges ─────────────────────────────────────────
                    _buildTrustBadges(
                      phoneVerified: phoneVerified,
                      paymentSetup: paymentSetup,
                      cardBg: cardBg,
                      borderColor: borderColor,
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                      isDark: isDark,
                    ),
                    const SizedBox(height: 16),

                    // ── Services ─────────────────────────────────────────────
                    if (services.isNotEmpty) ...[
                      _buildServicesSection(
                        services: services,
                        cardBg: cardBg,
                        borderColor: borderColor,
                        textPrimary: textPrimary,
                        textSecondary: textSecondary,
                      ),
                      const SizedBox(height: 16),
                    ],

                    // ── Activity ─────────────────────────────────────────────
                    _buildActivitySection(
                      createdAt: createdAt,
                      cardBg: cardBg,
                      borderColor: borderColor,
                      textPrimary: textPrimary,
                      textSecondary: textSecondary,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),

        // ── Fixed CTA bar ────────────────────────────────────────────────────
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _buildCtaBar(isDark: isDark, name: name),
        ),
      ],
    );
  }

  // ── Section builders ──────────────────────────────────────────────────────

  Widget _buildHero({
    required String name,
    required String initials,
    required String location,
    required DateTime? createdAt,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textSecondary,
    required bool isDark,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          // Avatar
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppTheme.primaryAccent, AppTheme.secondaryAccent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primaryAccent.withValues(alpha: 0.35),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Center(
              child: Text(
                initials.isEmpty ? '?' : initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Name
          Text(
            name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),

          // Rating placeholder
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ...List.generate(
                5,
                (i) => Icon(
                  i < 4 ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 16,
                  color: AppTheme.warningOrange,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Rating coming soon',
                style: TextStyle(
                  color: textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),

          // Location
          if (location.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.darkBackground
                    : AppTheme.lightBackground,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_on_rounded,
                      size: 14,
                      color: AppTheme.primaryAccent.withValues(alpha: 0.8)),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      location,
                      style: TextStyle(
                        color: textSecondary,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatsRow({
    required int postCount,
    required int jobsCount,
    required DateTime? createdAt,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    final memberSince = createdAt != null
        ? '${_monthAbbr(createdAt.month)} ${createdAt.year}'
        : '—';

    return Row(
      children: [
        Expanded(
          child: _StatBox(
            value: postCount > 0 ? '$postCount' : '—',
            label: 'Posts',
            icon: Icons.article_outlined,
            cardBg: cardBg,
            borderColor: borderColor,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatBox(
            value: jobsCount > 0 ? '$jobsCount' : '—',
            label: 'Applications',
            icon: Icons.work_outline_rounded,
            cardBg: cardBg,
            borderColor: borderColor,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatBox(
            value: memberSince,
            label: 'Member Since',
            icon: Icons.calendar_today_outlined,
            cardBg: cardBg,
            borderColor: borderColor,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            small: true,
          ),
        ),
      ],
    );
  }

  Widget _buildTrustBadges({
    required bool phoneVerified,
    required bool paymentSetup,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textSecondary,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_rounded,
                  size: 16, color: AppTheme.primaryAccent),
              const SizedBox(width: 8),
              Text(
                'Trust & Verification',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _TrustBadge(
            label: 'Provider Registered',
            sublabel: 'Verified member of Help24 network',
            verified: true,
          ),
          const SizedBox(height: 12),
          _TrustBadge(
            label: 'Phone Verified',
            sublabel: phoneVerified
                ? 'Phone number confirmed'
                : 'Phone not yet verified',
            verified: phoneVerified,
          ),
          const SizedBox(height: 12),
          _TrustBadge(
            label: 'Payment Setup',
            sublabel: paymentSetup
                ? 'M-Pesa payout configured'
                : 'Payout method not set up',
            verified: paymentSetup,
          ),
        ],
      ),
    );
  }

  Widget _buildServicesSection({
    required List<String> services,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textSecondary,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.build_circle_outlined,
                  size: 16, color: AppTheme.primaryAccent),
              const SizedBox(width: 8),
              Text(
                'Services Offered',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${services.length}',
                  style: const TextStyle(
                    color: AppTheme.primaryAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: services.map((service) {
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.primaryAccent.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.primaryAccent.withValues(alpha: 0.22),
                  ),
                ),
                child: Text(
                  service,
                  style: const TextStyle(
                    color: AppTheme.primaryAccent,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildActivitySection({
    required DateTime? createdAt,
    required Color cardBg,
    required Color borderColor,
    required Color textPrimary,
    required Color textSecondary,
    required bool isDark,
  }) {
    final memberSinceLabel = createdAt != null
        ? '${createdAt.day} ${_monthName(createdAt.month)} ${createdAt.year}'
        : 'Unknown';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.access_time_rounded,
                  size: 16, color: AppTheme.primaryAccent),
              const SizedBox(width: 8),
              Text(
                'Activity',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _ActivityRow(
            icon: Icons.person_add_alt_1_outlined,
            label: 'Member since',
            value: memberSinceLabel,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
          ),
          const SizedBox(height: 12),
          _ActivityRow(
            icon: Icons.circle,
            label: 'Status',
            value: 'Active provider',
            valueColor: AppTheme.successGreen,
            textPrimary: textPrimary,
            textSecondary: textSecondary,
            iconColor: AppTheme.successGreen,
            iconSize: 8,
          ),
          const SizedBox(height: 12),
          _ActivityRow(
            icon: Icons.star_rate_outlined,
            label: 'Rating',
            value: 'Coming soon',
            textPrimary: textPrimary,
            textSecondary: textSecondary,
          ),
        ],
      ),
    );
  }

  Widget _buildCtaBar({required bool isDark, required String name}) {
    final barBg = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final borderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    return Container(
      decoration: BoxDecoration(
        color: barBg,
        border: Border(
          top: BorderSide(color: borderColor),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Row(
        children: [
          // Message Provider
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => AuthGuard.requireAuth(
                context,
                action: 'message $name',
                onAuthenticated: () => _onMessageTap(context),
              ),
              icon: const Icon(Icons.chat_bubble_outline_rounded,
                  size: 16, color: AppTheme.primaryAccent),
              label: const Text(
                'Message',
                style: TextStyle(
                    color: AppTheme.primaryAccent,
                    fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(
                    color: AppTheme.primaryAccent, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Request Service
          Expanded(
            flex: 2,
            child: ElevatedButton.icon(
              onPressed: () => AuthGuard.requireAuth(
                context,
                action: 'request a service from $name',
                onAuthenticated: () => _onRequestServiceTap(context),
              ),
              icon: const Icon(Icons.handshake_outlined,
                  size: 16, color: Colors.white),
              label: const Text(
                'Request Service',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryAccent,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onRequestServiceTap(BuildContext context) {
    // Navigate back and open the post creation flow via the home screen's FAB.
    // Show an informational snackbar guiding the user.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Create a service request and providers like ${_provider?['name'] ?? 'this provider'} can apply.',
        ),
        backgroundColor: AppTheme.primaryAccent,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Got it',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _monthAbbr(int month) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return months[(month - 1).clamp(0, 11)];
  }

  static String _monthName(int month) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return months[(month - 1).clamp(0, 11)];
  }
}

// ── Reusable sub-widgets ──────────────────────────────────────────────────────

class _AppBarSliver extends StatelessWidget {
  final bool isDark;
  final String title;

  const _AppBarSliver({required this.isDark, required this.title});

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    return SafeArea(
      child: Container(
        color: bg,
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back_ios_new_rounded,
                  size: 20, color: textPrimary),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color cardBg;
  final Color borderColor;
  final Color textPrimary;
  final Color textSecondary;
  final bool small;

  const _StatBox({
    required this.value,
    required this.label,
    required this.icon,
    required this.cardBg,
    required this.borderColor,
    required this.textPrimary,
    required this.textSecondary,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: AppTheme.primaryAccent),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: textPrimary,
              fontSize: small ? 13 : 18,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _TrustBadge extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool verified;

  const _TrustBadge({
    required this.label,
    required this.sublabel,
    required this.verified,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary =
        isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final color = verified ? AppTheme.successGreen : AppTheme.warningOrange;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            verified ? Icons.verified_rounded : Icons.pending_outlined,
            size: 16,
            color: color,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                sublabel,
                style: TextStyle(
                  color: textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        if (verified)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.successGreen.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Verified',
              style: TextStyle(
                color: AppTheme.successGreen,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color textPrimary;
  final Color textSecondary;
  final Color? valueColor;
  final Color? iconColor;
  final double iconSize;

  const _ActivityRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.textPrimary,
    required this.textSecondary,
    this.valueColor,
    this.iconColor,
    this.iconSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon,
            size: iconSize,
            color: iconColor ??
                AppTheme.primaryAccent.withValues(alpha: 0.6)),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(color: textSecondary, fontSize: 13),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            color: valueColor ?? textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
