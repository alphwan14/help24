import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';

import '../../models/provider_reputation.dart';
import '../../models/user_model.dart';
import '../../services/profession_registry.dart';
import '../../services/provider_card_link.dart';
import '../../services/reputation_service.dart';
import '../../services/user_profile_service.dart';
import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';
import '../../utils/action_feedback.dart';

/// "My Help24 card" — Profile → Business.
///
/// A provider's digital business card: who they are, their Help24 record and
/// a QR code to their public profile. It exists so providers bring the
/// customers they already have — the ones met at independent gigs — onto
/// Help24 (docs/provider-card.md).
///
/// It says nothing about payment. "Payment protected" goes on the card only
/// when a real customer can actually pay into Help24's hold: production
/// M-Pesa, live payouts and a Play Store listing (Phase B of the same doc).
///
/// Everything on it is what the public profile already shows, read from the
/// same sources, so the card can never claim more than the profile it opens.
class ProviderCardScreen extends StatefulWidget {
  final String uid;

  const ProviderCardScreen({super.key, required this.uid});

  @override
  State<ProviderCardScreen> createState() => _ProviderCardScreenState();
}

class _ProviderCardScreenState extends State<ProviderCardScreen> {
  static const MethodChannel _share = MethodChannel('com.help24.help24/share');

  final GlobalKey _cardKey = GlobalKey();
  UserModel? _profile;
  ProviderReputation? _reputation;
  bool _loading = true;
  bool _failed = false;
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Profile and record together: the card is one answer, painted once.
  /// A missing record is not a failure — the card simply leaves the line out
  /// rather than inventing one.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    UserModel? profile;
    ProviderReputation? reputation;
    try {
      (profile, reputation) = await (
        UserProfileService.getUser(widget.uid),
        ReputationService.getReputation(widget.uid),
      ).wait;
    } catch (e) {
      debugPrint('[CARD] load failed: ${e.runtimeType}');
    }
    // The photo must be decoded before the card can be captured as an image,
    // or the shared PNG carries a placeholder where the face should be.
    if (!mounted) return;
    final photo = profile?.profileImage.trim() ?? '';
    if (photo.isNotEmpty) {
      await precacheImage(CachedNetworkImageProvider(photo), context, onError: (_, __) {});
      if (!mounted) return;
    }
    setState(() {
      _profile = profile;
      _reputation = reputation;
      _failed = profile == null;
      _loading = false;
    });
  }

  String get _shareText {
    final profession = ProfessionRegistry.instance.labelFor(_profile?.profession);
    return "I'm on Help24 as a $profession. See my profile and message me here: "
        '${ProviderCardLink.url(widget.uid)}';
  }

  /// The card as a PNG, through the phone's share sheet, with the link as text
  /// beside it. Anything that stops that copies the link instead, so the
  /// provider always leaves with something they can paste.
  Future<void> _shareCard() async {
    setState(() => _sharing = true);
    try {
      final boundary = _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('card not laid out');
      final image = await boundary.toImage(pixelRatio: 3);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (png == null) throw StateError('card did not encode');
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/shared_cards');
      await dir.create(recursive: true);
      final file = File('${dir.path}/help24-card.png');
      await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
      final opened = await _share.invokeMethod<bool>('shareImage', {'path': file.path, 'text': _shareText});
      if (opened != true) await _copyLink(fallback: true);
    } catch (e) {
      debugPrint('[CARD] share failed: ${e.runtimeType}');
      await _copyLink(fallback: true);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _copyLink({bool fallback = false}) async {
    await Clipboard.setData(ClipboardData(text: _shareText));
    if (!mounted) return;
    ActionFeedback.success(
      context,
      fallback ? "Couldn't open sharing, so your link is copied. Paste it anywhere." : 'Link copied. Paste it anywhere.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(title: const Text('My Help24 card')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed || profile == null
              ? _Message(
                  text: "We couldn't load your card just now.",
                  action: TextButton.icon(
                    onPressed: _load,
                    icon: const Icon(AppIcons.refresh),
                    label: const Text('Try again'),
                  ),
                )
              // Never a card with an email prefix where the name should be:
              // the name is the one thing a customer must recognise.
              : profile.name.trim().isEmpty
                  ? const _Message(text: 'Add your name in Professional Profile, then come back for your card.')
                  : ListView(
                      padding: const EdgeInsets.all(AppSpace.gutter),
                      children: [
                        Text(
                          'Share it with the customers you already have. When they scan it, your Help24 '
                          'profile opens and they can message you.',
                          style: text.bodyMedium,
                        ),
                        const SizedBox(height: AppSpace.xl),
                        Center(
                          child: FittedBox(
                            child: RepaintBoundary(
                              key: _cardKey,
                              child: ProviderCard(
                                name: profile.name.trim(),
                                profession: ProfessionRegistry.instance.labelFor(profile.profession),
                                photoUrl: profile.profileImage.trim(),
                                record: ProviderCard.recordLine(_reputation),
                                link: ProviderCardLink.qrUrl(widget.uid),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpace.xl),
                        FilledButton.icon(
                          onPressed: _sharing ? null : _shareCard,
                          icon: _sharing
                              ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(AppIcons.share),
                          label: const Text('Share card'),
                        ),
                        const SizedBox(height: AppSpace.md),
                        OutlinedButton.icon(
                          onPressed: _sharing ? null : _copyLink,
                          icon: const Icon(AppIcons.copy),
                          label: const Text('Copy link'),
                        ),
                        const SizedBox(height: AppSpace.lg),
                        Text(
                          'Your card shows what your public profile shows. Change your name, photo or '
                          'profession in Professional Profile and the card follows.',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final Widget? action;

  const _Message({required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            if (action != null) ...[const SizedBox(height: AppSpace.sm), action!],
          ],
        ),
      ),
    );
  }
}

/// The card itself, as shared and as printed.
///
/// Always the LIGHT palette, whatever the app theme: it leaves the phone as an
/// image and is read on other people's screens and on paper, where a dark card
/// is a dark rectangle. The QR is ink on white with its full quiet zone, so
/// it scans from a phone screen held at arm's length.
class ProviderCard extends StatelessWidget {
  static const double width = 340;

  final String name;
  final String profession;
  final String photoUrl;

  /// "★ 4.8 (12) · 9 jobs done on Help24", "New on Help24", or null when the
  /// record could not be read — then the line is left out, never guessed.
  final String? record;

  /// What the QR code carries.
  final String link;

  const ProviderCard({
    super.key,
    required this.name,
    required this.profession,
    required this.photoUrl,
    required this.record,
    required this.link,
  });

  /// The record line, in the same terms as the public profile.
  static String? recordLine(ProviderReputation? rep) {
    if (rep == null) return null;
    final parts = <String>[
      if (rep.hasReviews) '★ ${rep.averageRating.toStringAsFixed(1)} (${rep.totalReviews})',
      if (rep.completedJobs > 0) '${rep.completedJobs} ${rep.completedJobs == 1 ? 'job' : 'jobs'} done on Help24',
    ];
    return parts.isEmpty ? 'New on Help24' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    const c = AppColors.light;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: c.borderHairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SvgPicture.asset('assets/brand/help24-lockup.svg', height: 22),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                _Photo(url: photoUrl, name: name),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.contentPrimary, fontSize: 20, fontWeight: FontWeight.w700, height: 1.2),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        profession,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.accentText, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      if (record != null) ...[
                        const SizedBox(height: 4),
                        Text(record!, style: TextStyle(color: c.contentSecondary, fontSize: 13)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Center(
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: AppRadius.mdAll,
                border: Border.all(color: c.borderHairline),
              ),
              child: SizedBox.square(
                dimension: 176,
                child: CustomPaint(painter: QrPainter(link, color: c.contentPrimary)),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Scan to see my profile and message me',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.contentSecondary, fontSize: 13),
          ),
          const SizedBox(height: 18),
          Container(
            color: c.actionFill,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Find me on Help24',
                    style: TextStyle(color: c.contentOnAction, fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  ProviderCardLink.host,
                  style: TextStyle(color: c.accentFill, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Photo extends StatelessWidget {
  final String url;
  final String name;

  const _Photo({required this.url, required this.name});

  static const double size = 64;

  @override
  Widget build(BuildContext context) {
    const c = AppColors.light;
    final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final initials = parts.take(2).map((p) => p[0].toUpperCase()).join();
    final fallback = Center(
      child: Text(initials, style: TextStyle(color: c.accentText, fontSize: 22, fontWeight: FontWeight.w700)),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: c.accentSubtle),
      clipBehavior: Clip.antiAlias,
      child: url.isEmpty
          ? fallback
          : Image(
              image: CachedNetworkImageProvider(url),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }
}

/// A QR code painted module by module, quiet zone included.
class QrPainter extends CustomPainter {
  final String data;
  final Color color;

  QrPainter(this.data, {required this.color})
      : _image = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));

  final QrImage _image;

  /// The standard's minimum margin, in modules, on every side.
  static const int quietZone = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final count = _image.moduleCount;
    final span = count + quietZone * 2;
    // Whole logical pixels per module, centred: fractional modules leave
    // hairline seams between neighbours, which is what makes a code fail to
    // scan off a screenshot.
    final raw = size.shortestSide / span;
    final module = raw >= 1 ? raw.floorToDouble() : raw;
    final origin = (size.shortestSide - module * span) / 2 + quietZone * module;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (!_image.isDark(row, col)) continue;
        canvas.drawRect(
          Rect.fromLTWH(origin + col * module, origin + row * module, module, module),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(QrPainter old) => old.data != data || old.color != color;
}
