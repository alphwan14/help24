import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Privacy Policy — real content, scrollable, readable.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          _Heading('1. Data We Collect', textPrimary),
          _Body(
            'We collect information you provide when you sign up and use Help24: name, email or phone number, profile photo, and the content you post (requests, offers, jobs, messages). We also collect device information and usage data to improve the app and prevent abuse.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('2. How We Use Your Data', textPrimary),
          _Body(
            'We use your data to run the platform: to show your profile and posts to other users, to enable messaging and payments, and to send you notifications you have agreed to. We use usage data to improve our services, fix bugs, and keep the app secure.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('3. Data Sharing', textPrimary),
          _Body(
            'We do not sell your personal data. We may share data with service providers that help us operate the app (e.g. hosting, analytics), under strict confidentiality. We may share information when required by law or to protect the safety of our users.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('4. Security', textPrimary),
          _Body(
            'We use industry-standard measures to protect your data, including encryption and secure storage. You are responsible for keeping your account credentials safe. If you suspect unauthorized access, please contact us and change your password.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('5. Your Rights', textPrimary),
          _Body(
            'You can access and update your profile in the app. You can request a copy of your data or ask us to delete your account by contacting support@help24.com. Deleting your account may not remove all content that was shared with others (e.g. in chats).',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('6. Changes', textPrimary),
          _Body(
            'We may update this Privacy Policy from time to time. We will notify you of significant changes in the app or by email. Continued use of Help24 after changes means you accept the updated policy.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('7. Contact', textPrimary),
          _Body(
            'For privacy questions or requests, contact us at support@help24.com or through the app.',
            textSecondary,
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final Color color;

  const _Heading(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final String text;
  final Color color;

  const _Body(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: color,
        height: 1.5,
      ),
    );
  }
}
