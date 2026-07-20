// ─────────────────────────────────────────────────────────────────────────────
// Help24 Location Experience — Phase 1 (docs/design/location-sharing-experience.md)
//
// Location is Help24's coordination layer, not an attachment. This module owns
// every shared surface of the experience:
//   • LocationIntents.show(...)  — ONE sheet, three user intents, role-ordered
//   • PlaceCard / JourneyCard / RequestCard — purpose-built thread artifacts
//   • JourneyStatusStrip — persistent "on the way" state at the top of a chat
//   • MapThumbnail / LiveDot / distance + navigation helpers
//
// Invariants:
//   • Lite-mode map thumbnails are ALWAYS wrapped in AbsorbPointer — without it
//     the native map view claims the tap in the gesture arena and the parent
//     GestureDetector (open full screen) never fires.
//   • Every action is a real button OUTSIDE the map surface (maps are invisible
//     to screen readers); cards carry full text equivalents via Semantics.
//   • No billable APIs: distance is client-side haversine, Navigate uses the
//     free geo: intent.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:iconsax/iconsax.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/post_model.dart';
import '../theme/app_theme.dart';
import '../utils/time_utils.dart';

/// Result of the Place Picker: a pin plus the user's own name for it.
class PickedPlace {
  final double latitude;
  final double longitude;
  final String label;
  const PickedPlace({required this.latitude, required this.longitude, this.label = ''});
}

// ── Intent sheet ─────────────────────────────────────────────────────────────

/// The single location sheet: three intents, never a nested menu.
/// [travellerFirst] orders "On my way" on top (computed from the post role:
/// the person who did NOT author a request/job post is usually the traveller).
class LocationIntents {
  static Future<void> show(
    BuildContext context, {
    required bool travellerFirst,
    required VoidCallback onOnMyWay,
    required VoidCallback onSendPlace,
    required VoidCallback onRequestLocation,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final onMyWay = _IntentRow(
      icon: Iconsax.routing_2,
      color: AppTheme.primaryAccent,
      title: 'On my way',
      subtitle: 'Share your journey to this job',
      onTap: () {
        Navigator.pop(context);
        onOnMyWay();
      },
    );
    final sendPlace = _IntentRow(
      icon: Iconsax.location,
      color: AppTheme.successGreen,
      title: 'Send a place',
      subtitle: 'Drop a pin — the gate, the building, the exact spot',
      onTap: () {
        Navigator.pop(context);
        onSendPlace();
      },
    );
    final request = _IntentRow(
      icon: Iconsax.location_tick,
      color: AppTheme.secondaryAccent,
      title: 'Request location',
      subtitle: 'Ask them to share where to go',
      onTap: () {
        Navigator.pop(context);
        onRequestLocation();
      },
    );

    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _SheetGrabber(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Text(
                  'Location',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (travellerFirst) ...[onMyWay, sendPlace, request]
              else ...[sendPlace, onMyWay, request],
            ],
          ),
        ),
      ),
    );
  }
}

class _IntentRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _IntentRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 21),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 4),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

// ── Map thumbnail ────────────────────────────────────────────────────────────

/// Static lite-mode map preview for thread cards.
/// AbsorbPointer: without it the native map view claims the tap in the gesture
/// arena and the enclosing GestureDetector (open full screen) never fires.
class MapThumbnail extends StatelessWidget {
  final double latitude;
  final double longitude;

  const MapThumbnail({super.key, required this.latitude, required this.longitude});

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: GoogleMap(
        initialCameraPosition: CameraPosition(
          target: LatLng(latitude, longitude),
          zoom: 15,
        ),
        markers: {
          Marker(
            markerId: const MarkerId('loc'),
            position: LatLng(latitude, longitude),
          ),
        },
        liteModeEnabled: true,
        zoomControlsEnabled: false,
        scrollGesturesEnabled: false,
        zoomGesturesEnabled: false,
        myLocationButtonEnabled: false,
        mapToolbarEnabled: false,
      ),
    );
  }
}

// ── Shared helpers ───────────────────────────────────────────────────────────

/// "230 m away" / "2.1 km away" — client-side haversine, no API cost.
String? distanceAwayText({
  required double? fromLat,
  required double? fromLng,
  required double toLat,
  required double toLng,
}) {
  if (fromLat == null || fromLng == null) return null;
  final meters = Geolocator.distanceBetween(fromLat, fromLng, toLat, toLng);
  if (meters < 50) return 'Right here';
  if (meters < 1000) return '${meters.round()} m away';
  final km = meters / 1000;
  return '${km < 10 ? km.toStringAsFixed(1) : km.round()} km away';
}

/// Opens turn-by-turn in the Maps app via the free geo: intent; web fallback.
Future<void> launchNavigation(double lat, double lng, {String label = ''}) async {
  final name = label.trim().isEmpty ? 'Shared location' : label.trim();
  final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(name)})');
  if (await canLaunchUrl(geo) && await launchUrl(geo)) return;
  final web = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat%2C$lng');
  await launchUrl(web, mode: LaunchMode.externalApplication);
}

/// Journey/arrival clock stamp — device zone + device 12h/24h convention.
String _clockTime(BuildContext context, DateTime t) => formatClockTime(context, t);

// ── Live pulse dot ───────────────────────────────────────────────────────────

/// Pulsing "live" indicator. Static when the platform asks for reduced motion —
/// the LIVE label next to it carries the meaning without animation.
class LiveDot extends StatefulWidget {
  final double size;
  const LiveDot({super.key, this.size = 8});

  @override
  State<LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: const BoxDecoration(color: AppTheme.successGreen, shape: BoxShape.circle),
    );
    if (reduceMotion) return dot;
    return SizedBox(
      width: widget.size * 2.4,
      height: widget.size * 2.4,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) => Container(
              width: widget.size + (widget.size * 1.4 * _pulse.value),
              height: widget.size + (widget.size * 1.4 * _pulse.value),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.successGreen.withValues(alpha: 0.35 * (1 - _pulse.value)),
              ),
            ),
          ),
          dot,
        ],
      ),
    );
  }
}

// ── Place card ───────────────────────────────────────────────────────────────

/// A shared place in the thread: label, thumbnail, distance, Navigate.
/// This is a Help24 object — where the work happens — not a chat decoration.
class PlaceCard extends StatelessWidget {
  final Message message;
  final double? viewerLat;
  final double? viewerLng;
  final VoidCallback? onTap;

  const PlaceCard({
    super.key,
    required this.message,
    this.viewerLat,
    this.viewerLng,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mine = message.isMe;
    final lat = message.latitude!;
    final lng = message.longitude!;
    final hasLabel = message.text.isNotEmpty && message.text != 'Location';
    final title = hasLabel ? message.text : 'Pinned location';
    final distance = distanceAwayText(
      fromLat: viewerLat, fromLng: viewerLng, toLat: lat, toLng: lng);

    final titleColor = mine
        ? Colors.white
        : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary);
    final subColor = mine
        ? Colors.white70
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary);

    return Semantics(
      label:
          'Shared place: $title.${distance != null ? ' $distance.' : ''} Double tap to open the map.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 240,
                height: 124,
                child: MapThumbnail(latitude: lat, longitude: lng),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 240,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Iconsax.location, size: 15, color: mine ? Colors.white : AppTheme.successGreen),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: titleColor),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (distance != null)
                        Text(distance, style: TextStyle(fontSize: 12, color: subColor)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 240,
            height: 34,
            child: OutlinedButton.icon(
              onPressed: () => launchNavigation(lat, lng, label: hasLabel ? message.text : ''),
              icon: const Icon(Iconsax.routing_2, size: 15),
              label: const Text('Navigate'),
              style: OutlinedButton.styleFrom(
                foregroundColor: mine ? Colors.white : AppTheme.primaryAccent,
                side: BorderSide(
                  color: mine
                      ? Colors.white.withValues(alpha: 0.55)
                      : AppTheme.primaryAccent.withValues(alpha: 0.55),
                ),
                padding: EdgeInsets.zero,
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Journey card ─────────────────────────────────────────────────────────────

/// A journey in the thread. Three states:
///   live     → thumbnail + LIVE + "since HH:mm" (+ Stop / I've arrived for the sharer)
///   arrived  → mapless receipt: ✓ Arrived · HH:mm
///   ended    → muted "Journey ended", map still openable
/// How a journey should read RIGHT NOW. One continuous journey, one card that
/// mutates through these phases — never additional cards (Phase 2 §journey
/// evolution). The sender derives this from the JourneyEngine state; watchers
/// derive it from the row via [deriveWatcherJourneyPhase].
enum JourneyPhase { travelling, nearby, reconnecting, arrived, ended }

/// Human-facing ETA, e.g. "12 min away", "arriving shortly", "1 h 5 min away".
/// Presentation only — the engine owns the number, this owns the sentence.
String? etaText(int? seconds) {
  if (seconds == null) return null;
  if (seconds < 90) return 'Arriving shortly';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min away';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h away' : '$hours h $rest min away';
}

/// "4.8 km remaining" / "320 m remaining".
String? remainingText(double? meters) {
  if (meters == null) return null;
  if (meters < 950) return '${(meters / 10).round() * 10} m remaining';
  return '${(meters / 1000).toStringAsFixed(1)} km remaining';
}

/// Watcher-side phase derivation — a pure function of the row plus what this
/// device knows (the job's destination, and when the last realtime update for
/// this journey landed). No engine required: the traveller's device is the
/// only one running a JourneyEngine.
JourneyPhase deriveWatcherJourneyPhase(
  Message m, {
  double? destLat,
  double? destLng,
  DateTime? lastEventAt,
}) {
  if (m.isJourneyArrived) return JourneyPhase.arrived;
  if (!m.isLiveNow) return JourneyPhase.ended;
  // Signal health first: a frozen marker must never masquerade as live truth.
  if (lastEventAt != null &&
      DateTime.now().difference(lastEventAt) > const Duration(seconds: 75)) {
    return JourneyPhase.reconnecting;
  }
  if (destLat != null && destLng != null && m.hasValidCoordinates) {
    final d = Geolocator.distanceBetween(m.latitude!, m.longitude!, destLat, destLng);
    if (d <= 300) return JourneyPhase.nearby;
  }
  return JourneyPhase.travelling;
}

/// "Updated 40s ago" / "Updated 3m ago" — watcher-side freshness copy.
String? journeyFreshnessText(DateTime? lastEventAt) {
  if (lastEventAt == null) return null;
  final age = DateTime.now().difference(lastEventAt);
  if (age.inSeconds < 50) return null; // fresh — say nothing
  if (age.inMinutes < 1) return 'Updated ${age.inSeconds}s ago';
  if (age.inMinutes < 60) return 'Updated ${age.inMinutes}m ago';
  return 'Updated ${age.inHours}h ago';
}

class JourneyCard extends StatelessWidget {
  final Message message;
  final double? viewerLat;
  final double? viewerLng;
  /// True only on the device that is actively streaming this journey.
  final bool isSharing;
  /// Current phase of this journey (see [JourneyPhase]). Defaults to
  /// travelling for callers that have no richer knowledge.
  final JourneyPhase phase;
  /// When the last realtime update for this journey landed (watcher side) —
  /// drives the "Updated Xs ago" honesty line while reconnecting.
  final DateTime? lastEventAt;
  /// Live ETA in seconds and remaining metres (Phase 3). Null when routing is
  /// unavailable, in which case the card renders exactly as it did in Phase 2.
  final int? etaSeconds;
  final double? remainingMeters;
  /// Human destination name ("Mtopanga") when reverse geocoding resolved one.
  final String? destinationName;
  final VoidCallback? onStop;
  final VoidCallback? onArrived;
  final VoidCallback? onTap;

  const JourneyCard({
    super.key,
    required this.message,
    this.viewerLat,
    this.viewerLng,
    this.isSharing = false,
    this.phase = JourneyPhase.travelling,
    this.lastEventAt,
    this.etaSeconds,
    this.remainingMeters,
    this.destinationName,
    this.onStop,
    this.onArrived,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mine = message.isMe;
    final titleColor = mine
        ? Colors.white
        : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary);
    final subColor = mine
        ? Colors.white70
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary);

    // ── Arrived receipt — the journey's permanent conclusion in the thread ──
    if (message.isJourneyArrived) {
      final at = message.liveUntil ?? message.timestamp;
      return Semantics(
        label: 'Journey completed. Arrived at ${_clockTime(context, at)}.',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withValues(alpha: mine ? 0.28 : 0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check_rounded,
                  size: 18, color: mine ? Colors.white : AppTheme.successGreen),
            ),
            const SizedBox(width: 9),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Arrived',
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: titleColor)),
                Text('at ${_clockTime(context, at)}', style: TextStyle(fontSize: 12, color: subColor)),
              ],
            ),
          ],
        ),
      );
    }

    final live = message.isLiveNow;
    final lat = message.latitude!;
    final lng = message.longitude!;
    final title = message.text == 'Live location' ? 'Live location' : 'On my way';
    final distance = distanceAwayText(
      fromLat: viewerLat, fromLng: viewerLng, toLat: lat, toLng: lng);

    // ── Ended without arrival — quiet historical record ──
    if (!live) {
      return Semantics(
        label: 'Journey ended. Double tap to view the last shared position.',
        child: GestureDetector(
          onTap: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Iconsax.location_slash, size: 17, color: subColor),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Journey ended',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: titleColor)),
                  Text('Location no longer shared', style: TextStyle(fontSize: 12, color: subColor)),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // ── Live — one card, mutating through the journey's phases ──
    final reconnecting = phase == JourneyPhase.reconnecting;
    final freshness = journeyFreshnessText(lastEventAt);
    // ETA leads when routing has an answer — "12 min away" is what both sides
    // actually want to know; distance and start time are the fallback.
    final eta = etaText(etaSeconds);
    final remaining = remainingText(remainingMeters);
    final String statusLine;
    switch (phase) {
      case JourneyPhase.nearby:
        statusLine = [
          eta ?? 'Almost there…',
          if (remaining != null) remaining else if (!mine && distance != null) distance,
        ].join(' · ');
        break;
      case JourneyPhase.reconnecting:
        statusLine = [
          mine ? 'Reconnecting…' : 'Connection unsteady',
          if (!mine && freshness != null) freshness,
        ].join(' · ');
        break;
      case JourneyPhase.travelling:
      case JourneyPhase.arrived:
      case JourneyPhase.ended:
        statusLine = [
          eta ?? 'Live · since ${_clockTime(context, message.timestamp)}',
          if (remaining != null) remaining else if (!mine && distance != null) distance,
        ].join(' · ');
        break;
    }
    final String semanticsPhase = switch (phase) {
      JourneyPhase.nearby => mine ? 'You are almost there.' : 'They are almost there.',
      JourneyPhase.reconnecting =>
        'Connection unsteady.${freshness == null ? '' : ' $freshness.'}',
      _ => mine ? 'You are on the way.' : 'They are on the way.',
    };
    return Semantics(
      label:
          'Live journey: $semanticsPhase${distance != null && !mine ? ' $distance.' : ''} Sharing since ${_clockTime(context, message.timestamp)}. Double tap to open the live map.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 240,
                height: 124,
                child: MapThumbnail(latitude: lat, longitude: lng),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 240,
            child: Row(
              children: [
                if (reconnecting)
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                        color: AppTheme.warningOrange, shape: BoxShape.circle),
                  )
                else
                  const LiveDot(size: 7),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700, color: titleColor)),
                      // Deliberately NOT crossfaded. A switcher overlays the
                      // outgoing and incoming strings, and two different-width
                      // status lines ("Almost there…" → "2 min away · 480 m
                      // remaining") render on top of each other mid-transition
                      // as garbled text — observed on device. An ETA that
                      // changes at most once a minute does not need animating;
                      // clarity wins over polish here.
                      Text(
                        statusLine,
                        style: TextStyle(fontSize: 12, color: subColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (isSharing) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: 240,
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 34,
                      child: FilledButton.icon(
                        onPressed: onArrived,
                        icon: const Icon(Icons.check_rounded, size: 16),
                        label: const Text("I've arrived"),
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              mine ? Colors.white.withValues(alpha: 0.22) : AppTheme.successGreen,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.zero,
                          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 34,
                    child: TextButton(
                      onPressed: onStop,
                      style: TextButton.styleFrom(
                        foregroundColor: mine ? Colors.white70 : AppTheme.errorRed,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Stop'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Request card ─────────────────────────────────────────────────────────────

/// "Where exactly?" as a first-class object — replaces prose like
/// "Pin location please". Recipient answers with one tap into the Place Picker.
class RequestCard extends StatefulWidget {
  final Message message;
  final String partnerName;
  final VoidCallback? onShareNow;

  const RequestCard({
    super.key,
    required this.message,
    required this.partnerName,
    this.onShareNow,
  });

  @override
  State<RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<RequestCard> {
  // "Later" softly collapses the actions for this session only; the card stays
  // in history and stays answerable — no social-pressure mechanics, no decline
  // receipt on the requester's side.
  bool _deferred = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final mine = widget.message.isMe;
    final name = widget.partnerName.trim().isEmpty ? 'They' : widget.partnerName.trim();
    final titleColor = mine
        ? Colors.white
        : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary);
    final subColor = mine
        ? Colors.white70
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary);

    final body = mine ? 'You asked $name to share a location' : '$name asked for your location';

    return Semantics(
      label: mine
          ? 'You requested $name\'s location.'
          : '$name requested your location. Actions: share now, or later.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: (mine ? Colors.white : AppTheme.secondaryAccent)
                      .withValues(alpha: mine ? 0.22 : 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(Iconsax.location_tick,
                    size: 16, color: mine ? Colors.white : AppTheme.secondaryAccent),
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Location requested',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700, color: titleColor)),
                    Text(body,
                        style: TextStyle(fontSize: 12.5, color: subColor),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
          if (!mine && !_deferred && widget.onShareNow != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 32,
                  child: FilledButton(
                    onPressed: widget.onShareNow,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Share now'),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 32,
                  child: TextButton(
                    onPressed: () => setState(() => _deferred = true),
                    style: TextButton.styleFrom(
                      foregroundColor: subColor,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Later'),
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

// ── Journey status strip ─────────────────────────────────────────────────────

/// Compact persistent strip under the post banner while a journey is active.
/// Lightweight by design: one line, LIVE pill, Stop only for the sharer.
/// Context-aware quick action above the composer: the ONE next thing this
/// person is most likely here to do (answer a location request, start the
/// journey, rate after arrival). Rendered only when the lifecycle says it
/// makes sense; disappears the moment it doesn't.
class ContextActionBar extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const ContextActionBar({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          button: true,
          label: label,
          child: Material(
            color: AppTheme.primaryAccent.withValues(alpha: isDark ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 16, color: AppTheme.primaryAccent),
                    const SizedBox(width: 7),
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryAccent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class JourneyStatusStrip extends StatelessWidget {
  final String title;
  /// Drives tint, badge and dot so the strip evolves with the journey:
  /// travelling/nearby → green LIVE, reconnecting → amber, arrived → green ✓.
  final JourneyPhase phase;
  /// Optional second line: "12 min away · 4.8 km remaining" (Phase 3).
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onStop;

  const JourneyStatusStrip({
    super.key,
    required this.title,
    this.phase = JourneyPhase.travelling,
    this.subtitle,
    this.onTap,
    this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final arrived = phase == JourneyPhase.arrived;
    final reconnecting = phase == JourneyPhase.reconnecting;
    final accent = reconnecting ? AppTheme.warningOrange : AppTheme.successGreen;
    return Semantics(
      label: '$title.'
          '${arrived ? ' Journey completed.' : reconnecting ? ' Reconnecting.' : ' Live journey.'}'
          '${onStop != null ? ' Stop sharing button available.' : ' Double tap to open the live map.'}',
      child: Material(
        color: accent.withValues(alpha: isDark ? 0.10 : 0.08),
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    arrived ? Icons.check_rounded : Iconsax.routing_2,
                    size: 15,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  // Same reasoning as the journey card: overlaying two
                  // different-width strings reads as garbled text, and the
                  // strip's own colour/badge transitions already carry the
                  // sense of change.
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? AppTheme.darkTextPrimary
                                : AppTheme.lightTextPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty)
                          Text(
                            subtitle!,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: isDark
                                  ? AppTheme.darkTextSecondary
                                  : AppTheme.lightTextSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (arrived)
                  const Icon(Icons.check_circle_rounded,
                      size: 15, color: AppTheme.successGreen)
                else if (reconnecting) ...[
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                        color: AppTheme.warningOrange, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 4),
                  const Text(
                    'RECONNECTING',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: AppTheme.warningOrange,
                    ),
                  ),
                ] else ...[
                  const LiveDot(size: 6),
                  const SizedBox(width: 4),
                  const Text(
                    'LIVE',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                      color: AppTheme.successGreen,
                    ),
                  ),
                ],
                if (onStop != null) ...[
                  const SizedBox(width: 6),
                  SizedBox(
                    height: 30,
                    child: TextButton(
                      onPressed: onStop,
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.errorRed,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Stop sharing'),
                    ),
                  ),
                ] else
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
