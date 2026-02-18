import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import '../theme/app_theme.dart';

class ApplicationModal extends StatefulWidget {
  final String title;
  final String type; // 'job', 'request', or 'offer'
  final double? suggestedPrice;
  final Future<void> Function(String message, double proposedPrice) onSubmit;

  const ApplicationModal({
    super.key,
    required this.title,
    required this.type,
    this.suggestedPrice,
    required this.onSubmit,
  });

  @override
  State<ApplicationModal> createState() => _ApplicationModalState();
}

class _ApplicationModalState extends State<ApplicationModal> {
  final _messageController = TextEditingController();
  final _priceController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.suggestedPrice != null) {
      _priceController.text = widget.suggestedPrice!.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  String get _actionTitle {
    switch (widget.type) {
      case 'job':
        return 'Apply for Job';
      case 'request':
        return 'Respond to Request';
      case 'offer':
        return 'Accept Offer';
      default:
        return 'Submit Application';
    }
  }

  String get _priceLabel {
    switch (widget.type) {
      case 'job':
        return 'Expected Salary (KES)';
      case 'request':
        return 'Your Quote (KES)';
      case 'offer':
        return 'Agreed Price (KES)';
      default:
        return 'Proposed Price (KES)';
    }
  }

  String get _messagePlaceholder {
    switch (widget.type) {
      case 'job':
        return 'Introduce yourself and explain why you\'re a great fit for this position...';
      case 'request':
        return 'Describe how you can help with this request and your relevant experience...';
      case 'offer':
        return 'Add any questions or comments about the offer...';
      default:
        return 'Write your message...';
    }
  }

  void _submit() async {
    if (_messageController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please write a message'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    // Simulate network delay
    await Future.delayed(const Duration(milliseconds: 800));

    final price = double.tryParse(_priceController.text) ?? 0;
    await widget.onSubmit(_messageController.text, price);

    if (mounted) Navigator.pop(context);
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
                    child: Icon(
                      widget.type == 'job' ? Iconsax.briefcase : Iconsax.send_2,
                      color: AppTheme.primaryAccent,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _actionTitle,
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
              Text(
                'Your Message',
                style: Theme.of(context).textTheme.titleMedium,
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
              const SizedBox(height: 20),

              // Price Field
              Text(
                _priceLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _priceController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: 'Enter amount',
                  prefixIcon: const Icon(Iconsax.money),
                  prefixText: 'KES ',
                ),
              ),
              const SizedBox(height: 24),

              // Attachment hint
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark ? AppTheme.darkCard : AppTheme.lightBackground,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Iconsax.document_upload,
                      color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'You can attach your CV or portfolio after connecting',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
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
                      : Text(
                          widget.type == 'job' ? 'Send Application' : 'Send Response',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
