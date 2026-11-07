import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/verification_service.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../utils/action_feedback.dart';
import '../../utils/error_mapper.dart';

/// "Verify your identity" — the provider side of vetting (migration 135).
///
///   ID check    National ID / passport / Alien ID + a selfie holding it.
///               Needed to offer or apply for tutoring, driving, security and
///               house-cleaning work. Shows "ID verified" on the profile.
///   Care check  The ID check + a DCI Certificate of Good Conduct. Needed for
///               babysitting and caregiving. An eCitizen application receipt
///               is accepted for 30 days while the certificate is processed:
///               care listings go live marked "Certificate pending", but
///               applying for care jobs and being hired wait for the
///               certificate.
///
/// Any provider may do the ID check for the badge alone.
class VerificationScreen extends StatefulWidget {
  final String uid;

  /// Opens straight into the Care check (e.g. from a care listing).
  final VerificationKind? focus;

  const VerificationScreen({super.key, required this.uid, this.focus});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  late Future<VerificationStatus> _status;

  @override
  void initState() {
    super.initState();
    _status = VerificationService.myStatus();
  }

  void _reload() => setState(() => _status = VerificationService.myStatus());

  Future<void> _start(VerificationKind kind, VerificationStatus status) async {
    final sent = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _SubmitScreen(
          uid: widget.uid,
          kind: kind,
          // Once a receipt is accepted, the next care upload is the certificate.
          only: kind == VerificationKind.care && status.certificatePending ? VerificationDocument.certificate : null,
        ),
      ),
    );
    if (sent == true && mounted) {
      ActionFeedback.success(context, 'Sent. Help24 will review it within 24 hours.');
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Verify your identity')),
      body: FutureBuilder<VerificationStatus>(
        future: _status,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(ErrorMapper.toMessage(snap.error, context: ErrorContext.loadContent), textAlign: TextAlign.center),
                    const SizedBox(height: AppSpace.md),
                    OutlinedButton(onPressed: _reload, child: const Text('Try again')),
                  ],
                ),
              ),
            );
          }
          final s = snap.data ?? VerificationStatus.empty;
          final idTierCategories = s.tiers.entries.where((e) => e.value == 'id').map((e) => e.key).toList()..sort();
          final careTierCategories = s.tiers.entries.where((e) => e.value == 'care').map((e) => e.key).toList()..sort();
          final cards = [
            _CheckCard(
              title: 'ID check',
              subtitle: idTierCategories.isEmpty
                  ? 'Shows "ID verified" on your profile.'
                  : 'Needed for ${_list(idTierCategories)}. Shows "ID verified" on your profile — any provider can add it.',
              state: _idState(s),
              onAction: s.idVerified || (s.latestId?.isPending ?? false) ? null : () => _start(VerificationKind.id, s),
              actionLabel: s.latestId?.isRejected ?? false ? 'Send again' : 'Verify my ID',
            ),
            const SizedBox(height: AppSpace.md),
            _CheckCard(
              title: 'Care check',
              subtitle: careTierCategories.isEmpty
                  ? 'Your ID plus a Certificate of Good Conduct from the DCI.'
                  : 'Needed for ${_list(careTierCategories)}: your ID plus a Certificate of Good Conduct from the DCI.',
              state: _careState(s),
              onAction: _careAction(s) ? () => _start(VerificationKind.care, s) : null,
              actionLabel: s.certificatePending
                  ? 'Upload my certificate'
                  : (s.latestCare?.isRejected ?? false)
                      ? 'Send again'
                      : 'Start the Care check',
            ),
          ];
          if (widget.focus == VerificationKind.care) {
            cards.insertAll(0, [cards.removeAt(2), const SizedBox(height: AppSpace.md)]);
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              ...cards,
              const SizedBox(height: AppSpace.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(AppIcons.locked, size: 18, color: c.contentTertiary),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      'Only Help24 reviewers see your documents, and they are deleted 30 days after we decide. '
                      'Clients only ever see "ID verified" or "Care checked".',
                      style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  bool _careAction(VerificationStatus s) {
    if (s.careChecked) return false;
    if (s.latestCare?.isPending ?? false) return false;
    // The Care check includes the ID: it must at least be sent.
    final idSent = s.idVerified || (s.latestId?.isPending ?? false);
    return idSent;
  }

  _CheckState _idState(VerificationStatus s) {
    if (s.idVerified) return const _CheckState('ID verified', _Tone.positive);
    final l = s.latestId;
    if (l == null) return const _CheckState('Not started', _Tone.neutral);
    if (l.isPending) return _CheckState('In review — sent ${_date(l.submittedAt)}. We aim to answer within 24 hours.', _Tone.neutral);
    if (l.isRejected) return _CheckState('Not accepted: ${l.rejectionReason ?? 'please send it again.'}', _Tone.critical);
    return const _CheckState('Not started', _Tone.neutral);
  }

  _CheckState _careState(VerificationStatus s) {
    if (s.careChecked) return const _CheckState('Care checked', _Tone.positive);
    final l = s.latestCare;
    if (s.certificatePending) {
      final pendingUpload = l != null && l.isPending && l.document == VerificationDocument.certificate;
      return _CheckState(
        pendingUpload
            ? 'Certificate in review. Your receipt is accepted until ${_date(s.careExpiresAt)}.'
            : 'Certificate pending — upload it by ${_date(s.careExpiresAt)}. Until then your care listings show "Certificate pending", '
                'and you cannot apply for care jobs or be hired for them.',
        _Tone.caution,
      );
    }
    if (l == null) {
      final idSent = s.idVerified || (s.latestId?.isPending ?? false);
      return _CheckState(idSent ? 'Not started' : 'Send your ID first — the Care check includes it.', _Tone.neutral);
    }
    if (l.isPending) return _CheckState('In review — sent ${_date(l.submittedAt)}. We aim to answer within 24 hours.', _Tone.neutral);
    if (l.isRejected) return _CheckState('Not accepted: ${l.rejectionReason ?? 'please send it again.'}', _Tone.critical);
    if (l.isApproved && l.document == VerificationDocument.receipt) {
      return const _CheckState('Your receipt has expired. Upload your certificate to list care work again.', _Tone.critical);
    }
    return const _CheckState('Not started', _Tone.neutral);
  }

  static String _list(List<String> items) {
    final lower = items.map((e) => e.toLowerCase()).toList();
    if (lower.length <= 1) return lower.join();
    return '${lower.sublist(0, lower.length - 1).join(', ')} and ${lower.last}';
  }

  static String _date(DateTime? d) {
    if (d == null) return 'soon';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = d.toLocal();
    return '${l.day} ${months[l.month - 1]} ${l.year}';
  }
}

enum _Tone { neutral, positive, caution, critical }

class _CheckState {
  final String text;
  final _Tone tone;
  const _CheckState(this.text, this.tone);
}

class _CheckCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final _CheckState state;
  final VoidCallback? onAction;
  final String actionLabel;

  const _CheckCard({
    required this.title,
    required this.subtitle,
    required this.state,
    required this.onAction,
    required this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final (Color fg, Color bg, IconData icon) = switch (state.tone) {
      _Tone.positive => (c.positiveText, c.positiveSubtle, AppIcons.verifiedProvider),
      _Tone.caution => (c.cautionText, c.cautionSubtle, AppIcons.pending),
      _Tone.critical => (c.criticalText, c.criticalSubtle, AppIcons.warning),
      _Tone.neutral => (c.contentSecondary, c.surfaceSunken, AppIcons.info),
    };
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: c.borderHairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypeScale.headingS.copyWith(color: c.contentPrimary)),
          const SizedBox(height: AppSpace.xs),
          Text(subtitle, style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary)),
          const SizedBox(height: AppSpace.md),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(color: bg, borderRadius: AppRadius.mdAll),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: Text(state.text, style: AppTypeScale.bodyS.copyWith(color: fg))),
              ],
            ),
          ),
          if (onAction != null) ...[
            const SizedBox(height: AppSpace.md),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(onPressed: onAction, child: Text(actionLabel)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Pick the document, take each photo, send.
class _SubmitScreen extends StatefulWidget {
  final String uid;
  final VerificationKind kind;
  final VerificationDocument? only;

  const _SubmitScreen({required this.uid, required this.kind, this.only});

  @override
  State<_SubmitScreen> createState() => _SubmitScreenState();
}

class _PickedFile {
  final Uint8List bytes;
  final String extension;
  final String name;
  const _PickedFile(this.bytes, this.extension, this.name);
  bool get isPdf => extension.toLowerCase() == 'pdf';
}

class _SubmitScreenState extends State<_SubmitScreen> {
  VerificationDocument? _document;
  final Map<int, _PickedFile> _files = {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _document = widget.only;
  }

  List<VerificationDocument> get _choices =>
      widget.only != null ? [widget.only!] : VerificationDocument.forKind(widget.kind);

  bool get _complete => _document != null && _files.length == _document!.steps.length;

  Future<void> _pick(int step, {required bool camera}) async {
    final doc = _document!;
    try {
      _PickedFile? picked;
      if (doc.kind == VerificationKind.care && !camera) {
        // eCitizen hands out PDFs: accept one, or a photo.
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
          withData: true,
        );
        final f = result?.files.single;
        if (f != null && f.bytes != null) {
          picked = _PickedFile(f.bytes!, f.extension ?? 'pdf', f.name);
        }
      } else {
        final x = await ImagePicker().pickImage(
          source: camera ? ImageSource.camera : ImageSource.gallery,
          preferredCameraDevice: doc.steps[step].toLowerCase().contains('selfie') ? CameraDevice.front : CameraDevice.rear,
          imageQuality: 85,
          maxWidth: 2200,
        );
        if (x != null) {
          final ext = x.name.contains('.') ? x.name.split('.').last : 'jpg';
          picked = _PickedFile(await x.readAsBytes(), ext, x.name);
        }
      }
      if (picked == null || !mounted) return;
      if (picked.bytes.length > VerificationService.maxBytes) {
        ActionFeedback.info(context, 'That file is larger than 8 MB. Take the photo again, or choose a smaller PDF.');
        return;
      }
      setState(() => _files[step] = picked!);
    } catch (e) {
      if (mounted) ActionFeedback.failure(context, e, context_: ErrorContext.upload);
    }
  }

  Future<void> _send() async {
    final doc = _document;
    if (doc == null || !_complete || _sending) return;
    setState(() => _sending = true);
    try {
      final paths = <String>[];
      for (var i = 0; i < doc.steps.length; i++) {
        final f = _files[i]!;
        paths.add(await VerificationService.upload(uid: widget.uid, bytes: f.bytes, extension: f.extension));
      }
      await VerificationService.submit(kind: doc.kind, document: doc, files: paths);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        ActionFeedback.failure(context, e, context_: ErrorContext.upload, onRetry: _send);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final doc = _document;
    return Scaffold(
      appBar: AppBar(title: Text(widget.kind == VerificationKind.id ? 'ID check' : 'Care check')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          if (widget.only == null) ...[
            Text('Which document will you use?', style: AppTypeScale.headingS.copyWith(color: c.contentPrimary)),
            const SizedBox(height: AppSpace.sm),
            RadioGroup<VerificationDocument>(
              groupValue: _document,
              onChanged: (v) {
                if (_sending) return;
                setState(() {
                  _document = v;
                  _files.clear();
                });
              },
              child: Column(
                children: [
                  for (final d in _choices)
                    RadioListTile<VerificationDocument>(
                      value: d,
                      enabled: !_sending,
                      contentPadding: EdgeInsets.zero,
                      title: Text(d.label),
                      subtitle: d == VerificationDocument.receipt
                          ? const Text('Applied but still waiting? Your receipt is accepted for 30 days.')
                          : null,
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.md),
          ],
          if (doc != null) ...[
            Text(
              doc.kind == VerificationKind.id
                  ? 'Use a well-lit place. The whole card must be readable, and the selfie must show your face and the card together. '
                      'The name must match your Help24 profile.'
                  : 'Send the PDF from eCitizen, or a clear photo of every page. The name must match your Help24 profile.',
              style: AppTypeScale.bodyS.copyWith(color: c.contentSecondary),
            ),
            const SizedBox(height: AppSpace.md),
            for (var i = 0; i < doc.steps.length; i++)
              _StepTile(
                index: i + 1,
                label: doc.steps[i],
                file: _files[i],
                allowsFile: doc.kind == VerificationKind.care,
                enabled: !_sending,
                onCamera: () => _pick(i, camera: true),
                onFile: () => _pick(i, camera: false),
              ),
            const SizedBox(height: AppSpace.lg),
            SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: _complete && !_sending ? _send : null,
                child: _sending
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4))
                    : const Text('Send for review'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  final int index;
  final String label;
  final _PickedFile? file;
  final bool allowsFile;
  final bool enabled;
  final VoidCallback onCamera;
  final VoidCallback onFile;

  const _StepTile({
    required this.index,
    required this.label,
    required this.file,
    required this.allowsFile,
    required this.enabled,
    required this.onCamera,
    required this.onFile,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final f = file;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: f != null ? AppTheme.successGreen : c.borderHairline),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: ClipRRect(
              borderRadius: AppRadius.smAll,
              child: f == null
                  ? Container(
                      color: c.surfaceSunken,
                      alignment: Alignment.center,
                      child: Text('$index', style: AppTypeScale.headingS.copyWith(color: c.contentTertiary)),
                    )
                  : f.isPdf
                      ? Container(
                          color: c.surfaceSunken,
                          alignment: Alignment.center,
                          child: Icon(AppIcons.fileDocument, color: c.contentSecondary),
                        )
                      : Image.memory(f.bytes, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypeScale.bodyM.copyWith(color: c.contentPrimary)),
                if (f != null)
                  Text(f.isPdf ? f.name : 'Ready', style: AppTypeScale.meta.copyWith(color: AppTheme.successGreen)),
              ],
            ),
          ),
          IconButton(
            tooltip: f == null ? 'Take photo' : 'Retake',
            onPressed: enabled ? onCamera : null,
            icon: const Icon(AppIcons.camera),
          ),
          if (allowsFile)
            IconButton(
              tooltip: 'Choose a PDF or photo',
              onPressed: enabled ? onFile : null,
              icon: const Icon(AppIcons.attachment),
            )
          else
            IconButton(
              tooltip: 'Choose from gallery',
              onPressed: enabled ? onFile : null,
              icon: const Icon(AppIcons.gallery),
            ),
        ],
      ),
    );
  }
}
