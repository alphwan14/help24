import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import '../theme/app_theme.dart';

/// Help Center with real sections: Account, Payments, Jobs, Messaging, Safety.
class HelpCenterScreen extends StatelessWidget {
  const HelpCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textTertiary = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Help Center'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          _Section(
            icon: Iconsax.user,
            title: 'Account & Profile',
            children: [
              _Paragraph('You can sign in with your phone number or email. After signing in, complete your profile with your name and optional profile photo.'),
              _Paragraph('To edit your profile, go to Profile → tap your name or the edit icon. You can update your name, photo, and other details. Your profile is visible to others when you post requests, offers, or jobs.'),
            ],
            textSecondary: textSecondary,
            textTertiary: textTertiary,
          ),
          const SizedBox(height: 24),
          _Section(
            icon: Iconsax.wallet,
            title: 'Payments (M-Pesa)',
            children: [
              _Paragraph('Help24 supports payments via M-Pesa and other methods. When you agree on a price with a service provider, you can pay through the app.'),
              _Paragraph('For your safety, we recommend completing payment only after the work is done or using the agreed milestones. Never send money outside the app for a job arranged on Help24.'),
            ],
            textSecondary: textSecondary,
            textTertiary: textTertiary,
          ),
          const SizedBox(height: 24),
          _Section(
            icon: Iconsax.briefcase,
            title: 'Jobs & Services',
            children: [
              _Paragraph('Discover: Browse requests (people looking for help) and offers (people offering services). Use filters to find what you need.'),
              _Paragraph('Jobs: View job listings and apply with a message and your proposed price. Posters can accept an application and start a chat.'),
              _Paragraph('To post a request, offer, or job, tap the + button on the home screen and fill in the details. Add photos to get better responses.'),
            ],
            textSecondary: textSecondary,
            textTertiary: textTertiary,
          ),
          const SizedBox(height: 24),
          _Section(
            icon: Iconsax.message,
            title: 'Messaging',
            children: [
              _Paragraph('After you apply to a post or job, or when someone contacts you, you can chat in the Messages tab. All conversations are in one place.'),
              _Paragraph('You can send text messages and share your location when needed. Notifications will alert you when you receive a new message.'),
            ],
            textSecondary: textSecondary,
            textTertiary: textTertiary,
          ),
          const SizedBox(height: 24),
          _Section(
            icon: Iconsax.shield_tick,
            title: 'Safety & Trust',
            children: [
              _Paragraph('Only share contact or payment details through the app when you are ready to complete a deal. Be cautious of anyone asking for advance payment outside the app.'),
              _Paragraph('Report suspicious posts or users via the report option. We review reports and take action to keep the community safe.'),
            ],
            textSecondary: textSecondary,
            textTertiary: textTertiary,
          ),
          const SizedBox(height: 16),
          Text(
            'Need more help? Contact us at support@help24.com',
            style: TextStyle(fontSize: 14, color: textTertiary, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;
  final Color textSecondary;
  final Color textTertiary;

  const _Section({
    required this.icon,
    required this.title,
    required this.children,
    required this.textSecondary,
    required this.textTertiary,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 22, color: AppTheme.primaryAccent),
            const SizedBox(width: 10),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }
}

class _Paragraph extends StatelessWidget {
  final String text;

  const _Paragraph(this.text);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: color,
          height: 1.5,
        ),
      ),
    );
  }
}
