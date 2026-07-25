import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import '../theme/app_theme.dart';
import '../utils/action_feedback.dart';
import '../utils/error_mapper.dart';

/// Compose and send an application / offer.
///
/// CONTRACT — the modal owns the outcome
/// -------------------------------------
/// [onSubmit] does the work and nothing else: it returns normally on success
/// and THROWS on failure. It must not show messages of its own.
///
/// The previous contract was the inverse and unenforceable — this widget
/// swallowed every exception with `catch (_)` and a comment claiming "the
/// caller already showed a message", while the caller handled exactly one
/// exception type. Anything else (a rejected write, an expired session, a
/// dropped connection) reset the spinner and said nothing at all. Ownership now
/// sits in one place, so there is no assumption left to be wrong about.
class ApplicationModal extends StatefulWidget {
  final String title;
  final String type; // 'job', 'request', or 'offer'

  /// Performs the submission. Throws to report failure; must not show UI.
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

  /// The last failure, rendered in place. Null while the sheet is clean.
  AppFailure? _failure;

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

  /// Action verb on the submit button — MUST match the header per post type,
  /// so a "job" never shows "Apply for Job" above a "Send Offer" button.
  String get _submitLabel {
    switch (widget.type) {
      case 'job':
        return 'Apply';
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

  /// The success line, matched to what the user thinks they just did.
  String get _successMessage {
    switch (widget.type) {
      case 'job':
        return 'Application sent';
      case 'offer':
        return 'Request sent';
      default:
        return 'Offer sent';
    }
  }

  void _submit() async {
    setState(() {
      _isSubmitting = true;
      _failure = null;
    });
    try {
      await widget.onSubmit(_messageController.text.trim());
      if (!mounted) return;
      // Confirm on the way out: the sheet closing on its own is not, by itself,
      // evidence that anything reached the server.
      Navigator.pop(context);
      ActionFeedback.success(context, _successMessage);
    } catch (e) {
      if (!mounted) return;
      // Reported INSIDE the sheet rather than as a snackbar, so the message the
      // user typed survives and "try again" costs one tap instead of retyping.
      setState(() {
        _isSubmitting = false;
        _failure = ErrorMapper.toFailure(e, context: ErrorContext.apply);
      });
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

              // Failure, stated in place. The sheet stays open and the typed
              // message is preserved, so retrying costs a single tap.
              if (_failure != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppTheme.errorRed.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppTheme.errorRed.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 1),
                        child: Icon(Icons.error_outline_rounded,
                            color: AppTheme.errorRed, size: 19),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _failure!.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _failure!.message,
                              style: const TextStyle(fontSize: 13, height: 1.35),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

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
                          _failure == null ? _submitLabel : 'Try again',
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
