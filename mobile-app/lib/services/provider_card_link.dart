import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_links.dart';

/// A provider's Help24 card link: `https://help24.co.ke/p/<uid>`.
///
/// The card is how a provider brings the customers they already have onto
/// Help24 — shared as an image on WhatsApp, or shown as a QR code (the same
/// link with `?src=qr`). With Help24 installed, Android opens it here and the
/// provider's public profile opens; everyone else lands on the website's copy
/// of the card, which offers the download.
///
/// The id is the member's Firebase UID — the key `public_profiles` is already
/// read by, so the link exposes nothing the public profile does not.
class ProviderCardLink {
  ProviderCardLink._();

  static const String host = 'help24.co.ke';

  /// What the card's share text carries.
  static String url(String uid) => 'https://$host/p/$uid';

  /// What the card's QR code carries — the source tells a scan from a tap.
  static String qrUrl(String uid) => '${url(uid)}?src=qr';

  /// `/p/<uid>` on help24.co.ke → the uid, or null for any other link.
  @visibleForTesting
  static String? parse(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.scheme != 'https') return null;
    if (uri.host != host && uri.host != 'www.$host') return null;
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments[0] != 'p') return null;
    final uid = segments[1];
    return RegExp(r'^[A-Za-z0-9]{20,128}$').hasMatch(uid) ? uid : null;
  }

  static String? _pending;
  static final StreamController<void> _arrived = StreamController<void>.broadcast();

  /// Fires when a card link arrives while the app is running.
  static Stream<void> get arrivals => _arrived.stream;

  static bool _listening = false;

  /// Start listening for card links. Safe to call more than once.
  static Future<void> init() async {
    if (_listening) return;
    _listening = true;
    await AppLinks.listen((link) async {
      final uid = parse(link);
      if (uid == null) return;
      debugPrint('[CARD] link received');
      _pending = uid;
      _arrived.add(null);
    });
  }

  /// The profile a link asked for, once. Home opens it as soon as it is the
  /// screen in front — kept in memory only: a link that reaches a phone
  /// without Help24 is carried back by the website's "Open Help24" button.
  static String? takePending() {
    final uid = _pending;
    _pending = null;
    return uid;
  }
}
