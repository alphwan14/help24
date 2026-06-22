import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dispute_thread.dart';
import '../providers/auth_provider.dart';
import '../services/dispute_service.dart';
import '../theme/app_theme.dart';

/// DisputeThreadScreen — the participant's home for a single dispute. Drives off
/// GET /disputes/:id/thread (backend is source of truth). Supports: reading the
/// case timeline (messages + evidence merged chronologically), replying, and
/// uploading evidence (JPG/PNG/WEBP/PDF) to the private bucket via signed URLs.
class DisputeThreadScreen extends StatefulWidget {
  final String disputeId;
  final String? postTitle;

  const DisputeThreadScreen({super.key, required this.disputeId, this.postTitle});

  @override
  State<DisputeThreadScreen> createState() => _DisputeThreadScreenState();
}

class _DisputeThreadScreenState extends State<DisputeThreadScreen> {
  DisputeThread? _data;
  bool _loading = true;
  String? _error;
  bool _sending = false;
  bool _uploading = false;
  final _composer = TextEditingController();

  String get _uid => context.read<AuthProvider>().currentUserId ?? '';

  static const _extToMime = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
    'pdf': 'application/pdf',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final uid = _uid;
    if (uid.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Please sign in to view this dispute.';
      });
      return;
    }
    try {
      final data = await DisputeService.getThread(disputeId: widget.disputeId, userId: uid);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
        _error = null;
      });
    } on DisputeException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the dispute. Pull to retry.';
      });
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await DisputeService.reply(disputeId: widget.disputeId, userId: _uid, message: text);
      _composer.clear();
      await _load();
    } on DisputeException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attachAndUpload() async {
    if (_uploading) return;
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
        withData: true,
      );
    } catch (e) {
      _toast('Could not open the file picker.');
      return;
    }
    if (picked == null || picked.files.isEmpty) return;

    final uploads = <EvidenceUpload>[];
    for (final f in picked.files) {
      final bytes = f.bytes;
      final ext = (f.extension ?? '').toLowerCase();
      final mime = _extToMime[ext];
      if (bytes == null || mime == null) {
        _toast('Skipped "${f.name}" — only JPG, PNG, WEBP, PDF are allowed.');
        continue;
      }
      uploads.add(EvidenceUpload(fileName: f.name, mimeType: mime, bytes: bytes));
    }
    if (uploads.isEmpty) return;

    setState(() => _uploading = true);
    try {
      await DisputeService.uploadEvidence(
        disputeId: widget.disputeId,
        userId: _uid,
        files: uploads,
      );
      await _load();
      if (mounted) _toast('Evidence submitted.');
    } on DisputeException catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
      appBar: AppBar(
        title: Text(_data?.postTitle ?? widget.postTitle ?? 'Dispute'),
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(child: RefreshIndicator(onRefresh: _load, child: _buildBody(isDark))),
          if (_data != null) _buildComposer(_data!, isDark),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(children: [
        const SizedBox(height: 120),
        Icon(Icons.error_outline, size: 48, color: AppTheme.errorRed),
        const SizedBox(height: 12),
        Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center))),
      ]);
    }
    final d = _data!;
    final items = _timeline(d);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _headerCard(d, isDark),
        if (d.awaitingMyEvidence) ...[
          const SizedBox(height: 12),
          _evidenceRequestBanner(isDark),
        ],
        const SizedBox(height: 16),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Text('No messages yet.',
                  style: TextStyle(color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary)),
            ),
          )
        else
          for (final it in items) Padding(padding: const EdgeInsets.only(bottom: 12), child: it.build(isDark)),
      ],
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────────

  Widget _headerCard(DisputeThread d, bool isDark) {
    return _card(isDark, child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.gavel_outlined, size: 20, color: AppTheme.primaryAccent),
          const SizedBox(width: 8),
          const Expanded(child: Text('Dispute case', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          _pill(_statusLabel(d.status), _statusColor(d.status)),
        ]),
        const SizedBox(height: 12),
        _kv('Opened', _fmtTime(d.createdAt), isDark),
        if (d.priority != null) _kv('Priority', _cap(d.priority!), isDark),
        _kv('Handled by', d.assignedAdminName != null ? '${d.assignedAdminName} (support)' : 'Awaiting an admin', isDark),
        if (d.reason != null && d.reason!.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          _noteBox('Reason', d.reason!, isDark),
        ],
        if (d.isClosed) ...[
          const SizedBox(height: 10),
          _outcomeBox(d, isDark),
        ],
      ],
    ));
  }

  Widget _evidenceRequestBanner(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.warningOrange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warningOrange.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.upload_file_outlined, size: 18, color: AppTheme.warningOrange),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Admin has requested additional evidence',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Upload photos, screenshots or a PDF receipt to support your case.',
              style: TextStyle(fontSize: 13, color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _uploading ? null : _attachAndUpload,
              icon: _uploading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.attach_file),
              label: Text(_uploading ? 'Uploading…' : 'Upload evidence'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.warningOrange,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Timeline (messages + evidence merged) ───────────────────────────────────

  List<_Item> _timeline(DisputeThread d) {
    final items = <_Item>[];
    for (final m in d.messages) {
      // The evidence card itself represents an upload — skip the redundant marker.
      if (m.kind == 'evidence_submitted') continue;
      items.add(_Item(_parse(m.createdAt), (isDark) => _messageBubble(d, m, isDark)));
    }
    for (final e in d.evidence) {
      items.add(_Item(_parse(e.createdAt), (isDark) => _evidenceCard(e, isDark)));
    }
    items.sort((a, b) => a.at.compareTo(b.at));
    return items;
  }

  Widget _messageBubble(DisputeThread d, ThreadMessage m, bool isDark) {
    if (m.isSystem || m.isEvidenceRequest) {
      final isReq = m.isEvidenceRequest;
      return Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: (isReq ? AppTheme.warningOrange : AppTheme.primaryAccent).withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            children: [
              if (isReq)
                Text('Evidence requested',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.warningOrange)),
              Text(m.message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary)),
              const SizedBox(height: 2),
              Text(_fmtTime(m.createdAt),
                  style: TextStyle(fontSize: 10.5, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary)),
            ],
          ),
        ),
      );
    }

    final mine = m.senderType == d.viewerRole;
    final bg = mine
        ? AppTheme.primaryAccent
        : (m.isAdmin ? AppTheme.successGreen.withValues(alpha: 0.16) : (isDark ? AppTheme.darkCard : AppTheme.lightCard));
    final fg = mine ? Colors.white : null;
    final who = mine ? 'You' : (m.isAdmin ? 'Support' : 'The ${m.senderType}');
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: mine ? null : Border.all(color: (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary).withValues(alpha: 0.15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(who, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg ?? AppTheme.primaryAccent)),
              const SizedBox(height: 2),
              Text(m.message, style: TextStyle(fontSize: 14, color: fg)),
              const SizedBox(height: 3),
              Text(_fmtTime(m.createdAt),
                  style: TextStyle(fontSize: 10.5, color: fg?.withValues(alpha: 0.8) ?? (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _evidenceCard(ThreadEvidence e, bool isDark) {
    final mine = e.uploaderType == _data?.viewerRole;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary).withValues(alpha: 0.15)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(mine ? 'You · evidence' : '${_cap(e.uploaderType)} · evidence',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.primaryAccent)),
                const Spacer(),
                if (e.reviewed)
                  Icon(Icons.verified, size: 14, color: AppTheme.successGreen),
              ]),
              const SizedBox(height: 6),
              if (e.isImage)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(
                    e.fileUrl!,
                    height: 150,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _fileChip(e, isDark),
                  ),
                )
              else
                _fileChip(e, isDark),
              if (e.content != null && e.content!.trim().isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(e.content!, style: const TextStyle(fontSize: 13)),
              ],
              const SizedBox(height: 4),
              Text(_fmtTime(e.createdAt),
                  style: TextStyle(fontSize: 10.5, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileChip(ThreadEvidence e, bool isDark) {
    return Row(children: [
      Icon(e.type == 'document' ? Icons.picture_as_pdf_outlined : Icons.insert_drive_file_outlined,
          size: 20, color: AppTheme.primaryAccent),
      const SizedBox(width: 8),
      Expanded(child: Text(e.fileName ?? 'Attachment', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
    ]);
  }

  // ── Composer ────────────────────────────────────────────────────────────────

  Widget _buildComposer(DisputeThread d, bool isDark) {
    if (d.isClosed) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        child: Text(
          'This dispute is closed. The case record remains available above.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
        ),
      );
    }
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          border: Border(top: BorderSide(color: (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary).withValues(alpha: 0.15))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              onPressed: _uploading ? null : _attachAndUpload,
              icon: _uploading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.attach_file),
              tooltip: 'Attach evidence',
            ),
            Expanded(
              child: TextField(
                controller: _composer,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message support…',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  filled: true,
                  fillColor: (isDark ? AppTheme.darkBackground : AppTheme.lightBackground),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }

  // ── Small UI helpers ────────────────────────────────────────────────────────

  Widget _outcomeBox(DisputeThread d, bool isDark) {
    final dec = d.decisions.isNotEmpty ? d.decisions.last : null;
    String headline;
    switch (dec?.decisionType) {
      case 'FULL_RELEASE':
        headline = 'Full payment released to the provider.';
        break;
      case 'FULL_REFUND':
        headline = 'Full refund issued to the client.';
        break;
      case 'PARTIAL_SPLIT':
        headline = 'Payment was split between both parties.';
        break;
      case 'ESCALATE':
        headline = 'Escalated to a senior admin.';
        break;
      default:
        headline = 'Dispute resolved.';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.successGreen.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.successGreen.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.verified_outlined, size: 18, color: AppTheme.successGreen),
            const SizedBox(width: 8),
            const Text('Outcome', style: TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(headline, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          if (dec?.reasoning != null && dec!.reasoning!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(dec.reasoning!,
                style: TextStyle(fontSize: 13, color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary)),
          ],
        ],
      ),
    );
  }

  Widget _kv(String k, String v, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 92,
          child: Text(k, style: TextStyle(fontSize: 12.5, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary)),
        ),
        Expanded(child: Text(v, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _card(bool isDark, {required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary).withValues(alpha: 0.15)),
      ),
      child: child,
    );
  }

  Widget _pill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _noteBox(String label, String value, bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkBackground : AppTheme.lightBackground,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 13.5)),
      ]),
    );
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'open':
        return 'Open';
      case 'reviewing':
      case 'under_review':
        return 'Under review';
      case 'awaiting_client_evidence':
      case 'awaiting_provider_evidence':
        return 'Awaiting evidence';
      case 'awaiting_admin_review':
        return 'Admin reviewing';
      case 'escalated':
        return 'Escalated';
      case 'merged':
        return 'Merged';
      default:
        return s.startsWith('resolved') ? 'Resolved' : s;
    }
  }

  Color _statusColor(String s) {
    if (s.startsWith('resolved')) return AppTheme.successGreen;
    if (s == 'escalated') return AppTheme.errorRed;
    if (s == 'open') return AppTheme.warningOrange;
    if (s.startsWith('awaiting')) return AppTheme.warningOrange;
    return AppTheme.primaryAccent;
  }

  String _cap(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  DateTime _parse(String iso) => DateTime.tryParse(iso)?.toLocal() ?? DateTime.fromMillisecondsSinceEpoch(0);

  static const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String _fmtTime(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${dt.day} ${_months[dt.month - 1]} ${dt.year}, $h:$m $ampm';
  }
}

/// A chronological timeline entry (message or evidence) with its render closure.
class _Item {
  final DateTime at;
  final Widget Function(bool isDark) build;
  _Item(this.at, this.build);
}
