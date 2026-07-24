import 'package:flutter/material.dart';
import '../services/review_service.dart';
import '../theme/app_theme.dart';
import '../utils/error_mapper.dart';

/// Review submission — star rating (1–5) + optional written feedback.
/// Reachable from three entry points: the approval success screen, the Job
/// Lifecycle screen, and the review_requested notification.
class ReviewSubmissionScreen extends StatefulWidget {
  final String postId;
  final String clientUserId;
  final String? postTitle;

  const ReviewSubmissionScreen({
    super.key,
    required this.postId,
    required this.clientUserId,
    this.postTitle,
  });

  @override
  State<ReviewSubmissionScreen> createState() => _ReviewSubmissionScreenState();
}

class _ReviewSubmissionScreenState extends State<ReviewSubmissionScreen> {
  int _rating = 0;
  final _commentController = TextEditingController();
  bool _submitting = false;
  bool _submitted = false;
  String? _error;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_rating < 1) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ReviewService.submit(
        postId: widget.postId,
        clientId: widget.clientUserId,
        rating: _rating,
        comment: _commentController.text,
      );
      if (mounted) setState(() => _submitted = true);
    } on ReviewException catch (e) {
      if (mounted) setState(() => _error = ErrorMapper.toMessage(e, context: ErrorContext.save));
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not submit your review. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        title: Text('Rate your experience',
            style: TextStyle(color: textPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: _submitted ? _successView(textPrimary, textSecondary) : _formView(isDark, textPrimary, textSecondary),
    );
  }

  Widget _formView(bool isDark, Color textPrimary, Color textSecondary) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.postTitle != null && widget.postTitle!.isNotEmpty) ...[
            Text(widget.postTitle!,
                textAlign: TextAlign.center,
                style: TextStyle(color: textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 8),
          Text('How was the provider?',
              textAlign: TextAlign.center,
              style: TextStyle(color: textSecondary, fontSize: 14)),
          const SizedBox(height: 20),
          // Star picker
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              final value = i + 1;
              final filled = value <= _rating;
              return IconButton(
                onPressed: _submitting ? null : () => setState(() => _rating = value),
                icon: Icon(
                  filled ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 44,
                  color: filled ? AppTheme.warningOrange : textSecondary.withValues(alpha: 0.5),
                ),
              );
            }),
          ),
          if (_rating > 0) ...[
            const SizedBox(height: 4),
            Text(_ratingWord(_rating),
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.warningOrange, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 24),
          TextField(
            controller: _commentController,
            enabled: !_submitting,
            maxLines: 4,
            maxLength: 1000,
            decoration: InputDecoration(
              hintText: 'Add a comment (optional)',
              filled: true,
              fillColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(_error!, style: TextStyle(color: AppTheme.errorRed, fontSize: 13)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: (_rating >= 1 && !_submitting) ? _submit : null,
              child: _submitting
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Submit Review', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _submitting ? null : () => Navigator.pop(context),
            child: Text('Skip', style: TextStyle(color: textSecondary)),
          ),
        ],
      ),
    );
  }

  Widget _successView(Color textPrimary, Color textSecondary) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, color: AppTheme.successGreen, size: 64),
            const SizedBox(height: 16),
            Text('Thanks for your review!',
                style: TextStyle(color: textPrimary, fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text('Your feedback helps other clients hire with confidence.',
                textAlign: TextAlign.center, style: TextStyle(color: textSecondary, fontSize: 14)),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, 'reviewed'),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _ratingWord(int r) {
    switch (r) {
      case 1:
        return 'Poor';
      case 2:
        return 'Fair';
      case 3:
        return 'Good';
      case 4:
        return 'Very Good';
      case 5:
        return 'Excellent';
      default:
        return '';
    }
  }
}
