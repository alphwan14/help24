import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconsax/iconsax.dart';

import '../models/service_record.dart';
import '../services/service_records_service.dart';
import '../theme/app_theme.dart';
import '../utils/action_feedback.dart';
import '../utils/error_mapper.dart';
import '../utils/format_utils.dart';
import '../widgets/loading_empty_offline.dart';

/// The Help24 platform receipt for a service.
///
/// This is Help24's own document, and it says so. It REFERENCES the underlying
/// mobile-money transaction rather than impersonating it: the M-Pesa reference
/// appears under its own heading, clearly separate from the Help24 receipt
/// number, because a Help24 receipt is not a Safaricom receipt and must never
/// be mistaken for one.
///
/// Every figure on this page comes from the backend's transaction record. None
/// is computed here, and nothing is shown when the underlying value is absent.
class ReceiptScreen extends StatefulWidget {
  final String postId;
  final String uid;

  const ReceiptScreen({super.key, required this.postId, required this.uid});

  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  ReceiptResult? _result;
  String? _error;
  bool _loading = true;

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
      final result = await ServiceRecordsService.getReceipt(
        postId: widget.postId,
        userId: widget.uid,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ServiceRecordsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ErrorMapper.toMessage(e, context: ErrorContext.loadContent);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = ErrorMapper.toMessage(e, context: ErrorContext.loadContent);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: ReconnectListener(
        onReconnect: _load,
        child: RefreshIndicator(onRefresh: _load, child: _buildBody()),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const LoadingView(message: 'Loading receipt…');
    if (_error != null) return ErrorRetryView(message: _error!, onRetry: _load);

    final result = _result;
    if (result == null) {
      return ErrorRetryView(message: 'We could not load this receipt.', onRetry: _load);
    }

    return switch (result) {
      ReceiptUnavailable() => _Unavailable(result: result, onRetry: _load),
      ServiceReceipt() => _ReceiptDocument(receipt: result),
    };
  }
}

/// No receipt yet, and an honest reason why — never a placeholder document and
/// never an invented reference number.
class _Unavailable extends StatelessWidget {
  final ReceiptUnavailable result;
  final Future<void> Function() onRetry;

  const _Unavailable({required this.result, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.1),
        EmptyStateView(
          icon: result.isPending ? Iconsax.clock : Iconsax.receipt_item,
          title: result.isPending ? 'Payment still processing' : 'No receipt yet',
          subtitle: result.message,
          actions: [
            if (result.isPending)
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 20),
                label: const Text('Check again'),
              ),
          ],
        ),
      ],
    );
  }
}

class _ReceiptDocument extends StatelessWidget {
  final ServiceReceipt receipt;

  const _ReceiptDocument({required this.receipt});

  /// Status colour, consistent with the settlement colours used on the
  /// lifecycle screen and the history list.
  Color _statusColor() => switch (receipt.status) {
        'RELEASED' => AppTheme.successGreen,
        'REFUNDED' => AppTheme.successGreen,
        'PARTIALLY_REFUNDED' => AppTheme.warningOrange,
        'DISPUTED' => AppTheme.errorRed,
        'UNDER_REVIEW' => AppTheme.errorRed,
        _ => AppTheme.primaryAccent,
      };

  /// Everyday language, never "escrow" — see ServiceReceipt.statusLabel.
  String _statusLabel() => receipt.statusLabel;

  String _fmtDate(DateTime? d) {
    if (d == null) return '—';
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour < 12 ? 'am' : 'pm';
    return '${d.day} ${months[d.month - 1]} ${d.year}, $h:$m$ampm';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;
    final statusColor = _statusColor();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Masthead ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryAccent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Center(
                            child: Text(
                              'H',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'HELP24',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'SERVICE RECEIPT',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6,
                        color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // The Help24 document number — the identifier this receipt
                    // is filed under. Tap to copy, because the first thing a
                    // person does with a receipt number is quote it to support.
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: receipt.receiptNumber));
                        ActionFeedback.success(context, 'Receipt number copied');
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Text(
                              receipt.receiptNumber,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Iconsax.copy,
                              size: 15,
                              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // ── Status ───────────────────────────────────────────
                    // On its own line rather than squeezed beside the HELP24
                    // mark: the longest label ("PARTIALLY REFUNDED") does not
                    // fit next to the wordmark on a narrow screen, and a
                    // truncated payment status ("PAYMENT PR…") is worse than
                    // no chip at all. Full width here means no label can ever
                    // be clipped, whatever the state machine returns.
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _statusLabel(),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.7,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Divider(height: 1, color: border),

              // ── Service ─────────────────────────────────────────────────
              _Block(
                isDark: isDark,
                rows: [
                  _Row('Service', receipt.serviceTitle, emphasis: true),
                  if (receipt.category != null) _Row('Category', receipt.category!),
                  if (receipt.location != null) _Row('Location', receipt.location!),
                ],
              ),
              Divider(height: 1, color: border),

              // ── Parties ─────────────────────────────────────────────────
              _Block(
                isDark: isDark,
                rows: [
                  _Row('Customer', receipt.customerName ?? '—'),
                  _Row('Provider', receipt.providerName ?? '—'),
                ],
              ),
              Divider(height: 1, color: border),

              // ── Payment ─────────────────────────────────────────────────
              // The mobile-money reference sits here, under the payment
              // method that produced it — never beside the Help24 number,
              // where the two could be read as the same thing.
              _Block(
                isDark: isDark,
                rows: [
                  _Row('Payment method', receipt.paymentMethodLabel),
                  if (receipt.providerReferenceVisible)
                    _Row(
                      '${receipt.paymentMethodLabel} reference',
                      receipt.providerReference ?? 'Pending confirmation',
                      mono: true,
                    ),
                  _Row('Help24 transaction', _shortId(receipt.transactionId), mono: true),
                  _Row('Date', _fmtDate(receipt.paidAt)),
                  if (receipt.settledAt != null) _Row('Settled', _fmtDate(receipt.settledAt)),
                ],
              ),
              Divider(height: 1, color: border),

              // ── Money ───────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                child: Column(
                  children: [
                    if (receipt.amount != null)
                      _MoneyRow('Service amount', receipt.amount!, isDark: isDark),
                    if (receipt.platformFee != null && receipt.platformFee! > 0) ...[
                      const SizedBox(height: 8),
                      _MoneyRow('Help24 service fee', receipt.platformFee!, isDark: isDark),
                    ],
                    if (receipt.refundedAmount != null && receipt.refundedAmount! > 0) ...[
                      const SizedBox(height: 8),
                      _MoneyRow(
                        'Refunded to customer',
                        receipt.refundedAmount!,
                        isDark: isDark,
                        color: AppTheme.warningOrange,
                      ),
                    ],
                    if (receipt.totalPaid != null) ...[
                      const SizedBox(height: 12),
                      Divider(height: 1, color: border),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text(
                            'Total paid',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          Text(
                            formatPriceDisplay(receipt.totalPaid!),
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // ── Status explanation ──────────────────────────────────────
              if (receipt.statusExplanation.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.07),
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Iconsax.info_circle, size: 16, color: statusColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          receipt.statusExplanation,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: isDark
                                ? AppTheme.darkTextSecondary
                                : AppTheme.lightTextSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),

        const SizedBox(height: 14),

        // ── Footer: what this document is, and is not ────────────────────
        // Stated plainly so nobody presents a Help24 receipt as a Safaricom
        // one, or goes looking for this number in their M-Pesa statement.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            receipt.providerReferenceVisible
                ? 'This is a Help24 receipt for a payment made through the Help24 platform. '
                    'It is issued by Help24 and is separate from the ${receipt.paymentMethodLabel} '
                    'confirmation sent to your phone.'
                : 'This is a Help24 record of the payment for this job. The customer\'s '
                    '${receipt.paymentMethodLabel} reference is not shown here.',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.45,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
          ),
        ),
      ],
    );
  }

  /// Transaction ids are UUIDs; the leading segment is enough to quote to
  /// support and short enough to read. The full id is never needed on screen.
  static String _shortId(String id) {
    if (id.isEmpty) return '—';
    final head = id.split('-').first;
    return head.toUpperCase();
  }
}

// ── Layout primitives ────────────────────────────────────────────────────────

class _Row {
  final String label;
  final String value;
  final bool emphasis;
  final bool mono;
  const _Row(this.label, this.value, {this.emphasis = false, this.mono = false});
}

class _Block extends StatelessWidget {
  final List<_Row> rows;
  final bool isDark;

  const _Block({required this.rows, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final label = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(
                    rows[i].label,
                    style: TextStyle(fontSize: 12.5, color: label),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    rows[i].value,
                    style: TextStyle(
                      fontSize: rows[i].emphasis ? 15 : 13.5,
                      fontWeight: rows[i].emphasis ? FontWeight.w700 : FontWeight.w500,
                      fontFamily: rows[i].mono ? 'monospace' : null,
                      letterSpacing: rows[i].mono ? 0.3 : null,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  final String label;
  final double value;
  final bool isDark;
  final Color? color;

  const _MoneyRow(this.label, this.value, {required this.isDark, this.color});

  @override
  Widget build(BuildContext context) {
    final sub = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Row(
      children: [
        Text(label, style: TextStyle(fontSize: 13.5, color: color ?? sub)),
        const Spacer(),
        Text(
          formatPriceDisplay(value),
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: color),
        ),
      ],
    );
  }
}
