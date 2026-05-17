import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Terms of Service — real content, scrollable, readable.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms of Service'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          _Heading('1. Acceptance of Terms', textPrimary),
          _Body(
            'By using Help24, you agree to these Terms of Service. If you do not agree, please do not use the app. We may update these terms from time to time; continued use after changes means you accept the updated terms.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('2. User Responsibilities', textPrimary),
          _Body(
            'You are responsible for the accuracy of the information you post and for your conduct on the platform. You must be at least 18 years old to use Help24. You may not use the app for any illegal purpose or to harm others.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('3. Platform Role', textPrimary),
          _Body(
            'Help24 is an intermediary that connects people who need services with people who offer them. We do not employ service providers or guarantee the quality of work. Any agreement is between you and the other user. We are not liable for disputes, quality of service, or payments made outside the app.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('4. Payments & Escrow', textPrimary),
          _Body(
            'When you pay through Help24, we may hold funds in escrow until the work is completed or released according to the agreement. Fees may apply as stated in the app. Refunds are subject to our refund policy and the specific circumstances of the transaction.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('5. Prohibited Activities', textPrimary),
          _Body(
            'You may not: post false or misleading content; harass or threaten other users; use the app for fraud or money laundering; post illegal services or content; circumvent our safety or payment systems; or create multiple accounts to abuse the platform. We may suspend or terminate accounts that violate these terms.',
            textSecondary,
          ),
          const SizedBox(height: 20),
          _Heading('6. Contact', textPrimary),
          _Body(
            'For questions about these terms, contact us at support@help24.com or through the app.',
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
