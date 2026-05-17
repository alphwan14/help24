import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import '../theme/app_theme.dart';

class ApplicationModal extends StatefulWidget {
  final String title;
  final String type; // 'job', 'request', or 'offer'
  final Future<void> Function(String message) onSubmit;

  const ApplicationModal({
    super.key,
    required this.title,
    required this.type,
    required this.onSubmit,
  });

  @override
  State<ApplicationModal> createState() => _ApplicationModalState();
}

class _ApplicationModalState extends State<ApplicationModal> {
  final _messageController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  String get _headerTitle {
    switch (widget.type) {
      case 'job':
        return 'Apply for Job';
      case 'request':
        return 'Send Offer';
      case 'offer':
        return 'Request Service';
      default:
        return 'Send Offer';
    }
  }

  String get _messagePlaceholder {
    switch (widget.type) {
      case 'job':
        return 'Introduce yourself and explain why you\'re a great fit…';
      case 'request':
        return 'Tell them about yourself or ask any questions (optional)';
      case 'offer':
        return 'Add any questions or comments about the offer…';
      default:
        return 'Add a message (optional)';
    }
  }

  void _submit() async {
    setState(() => _isSubmitting = true);
    try {
      await widget.onSubmit(_messageController.text.trim());
      // onSubmit completed without error — close the modal.
      if (mounted) Navigator.pop(context);
    } catch (_) {
      // onSubmit threw (e.g. DuplicateApplicationException handled upstream).
      // Reset the spinner so the user isn't stuck; the caller already showed a message.
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
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
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Header
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Iconsax.send_2, color: AppTheme.primaryAccent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _headerTitle,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.title,
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Message Field
              Row(
                children: [
                  Text('Message', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 6),
                  Text(
                    '(optional)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _messageController,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: _messagePlaceholder,
                  hintMaxLines: 3,
                ),
              ),
              const SizedBox(height: 24),

              // Submit Button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          'Send Offer',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
