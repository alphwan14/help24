import 'package:flutter/material.dart';
import '../services/jobs_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_mapper.dart';

/// Provider screen: mark a job as complete and optionally leave a note.
class MarkCompleteScreen extends StatefulWidget {
  final String postId;
  final String postTitle;
  final String providerUserId;

  const MarkCompleteScreen({
    super.key,
    required this.postId,
    required this.postTitle,
    required this.providerUserId,
  });

  @override
  State<MarkCompleteScreen> createState() => _MarkCompleteScreenState();
}

class _MarkCompleteScreenState extends State<MarkCompleteScreen> {
  final _noteController = TextEditingController();
  bool _submitting = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await JobsService.markComplete(
        postId: widget.postId,
        providerUserId: widget.providerUserId,
        providerNote: _noteController.text.trim().isEmpty
            ? null
            : _noteController.text.trim(),
      );
      if (!mounted) return;
      setState(() => _done = true);
    } on JobsException catch (e) {
      setState(() => _error = ErrorMapper.toMessage(e));
    } catch (_) {
      setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final card = isDark ? AppTheme.darkCard : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1A1A2E);
    final textSecondary = isDark ? Colors.white54 : Colors.black54;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: textPrimary, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Mark Job as Done',
          style: TextStyle(
            color: textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
      body: _done ? _SuccessView(postTitle: widget.postTitle, textPrimary: textPrimary) : _Form(
        postTitle: widget.postTitle,
        noteController: _noteController,
        submitting: _submitting,
        error: _error,
        card: card,
        textPrimary: textPrimary,
        textSecondary: textSecondary,
        onSubmit: _submit,
      ),
    );
  }
}

class _Form extends StatelessWidget {
  final String postTitle;
  final TextEditingController noteController;
  final bool submitting;
  final String? error;
  final Color card;
  final Color textPrimary;
  final Color textSecondary;
  final VoidCallback onSubmit;

  const _Form({
    required this.postTitle,
    required this.noteController,
    required this.submitting,
    required this.error,
    required this.card,
    required this.textPrimary,
    required this.textSecondary,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryAccent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.check_circle_outline_rounded,
                          color: AppTheme.primaryAccent, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Completing Job',
                              style: TextStyle(
                                  color: textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(postTitle,
                              style: TextStyle(color: textSecondary, fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryAccent.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          color: AppTheme.primaryAccent, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This will notify the client. Funds are released only after they approve.',
                          style: TextStyle(
                              color: textSecondary, fontSize: 12, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('Completion Note (optional)',
              style: TextStyle(
                  color: textPrimary, fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: card,
              borderRadius: BorderRadius.circular(14),
            ),
            child: TextField(
              controller: noteController,
              maxLines: 4,
              maxLength: 500,
              style: TextStyle(color: textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText:
                    'Describe what you completed, any deliverables, or how to access them…',
                hintStyle: TextStyle(color: textSecondary, fontSize: 13),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(14),
                counterStyle: TextStyle(color: textSecondary, fontSize: 11),
              ),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded,
                      color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(error!,
                        style: const TextStyle(color: Colors.red, fontSize: 13)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: submitting ? null : onSubmit,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.successGreen,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              icon: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_rounded, size: 20),
              label: Text(
                submitting ? 'Submitting…' : 'Mark as Complete',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  final String postTitle;
  final Color textPrimary;

  const _SuccessView({required this.postTitle, required this.textPrimary});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withOpacity(0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check_circle_rounded,
                  color: AppTheme.successGreen, size: 56),
            ),
            const SizedBox(height: 24),
            Text('Completion Submitted!',
                style: TextStyle(
                    color: textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 22)),
            const SizedBox(height: 12),
            Text(
              'The client has been notified and will review your work. Funds will be released once they approve.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: textPrimary.withOpacity(0.6),
                  fontSize: 14,
                  height: 1.5),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context, true),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: Text('Back to Job',
                    style: TextStyle(
                        color: textPrimary, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
