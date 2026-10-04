// ─────────────────────────────────────────────────────────────────────────────
// Help24 Location Experience — Phase 1 (docs/design/location-sharing-experience.md)
//
// Location is Help24's coordination layer, not an attachment. This module owns
// every shared surface of the experience:
//   • LocationIntents.show(...)  — ONE sheet, three user intents, role-ordered
//   • JourneyCard / RequestCard — purpose-built thread artifacts (a shared
//     place is the chat's location bubble, `ChatLocationBubble`)
//   • JourneyStatusStrip — persistent "on the way" state at the top of a chat
//   • MapThumbnail / LiveDot / distance + directions helpers
//
// Invariants:
//   • Lite-mode map thumbnails are ALWAYS wrapped in AbsorbPointer — without it
//     the native map view claims the tap in the gesture arena and the parent
//     GestureDetector (open full screen) never fires.
//   • Every action is a real button OUTSIDE the map surface (maps are invisible
//     to screen readers); cards carry full text equivalents via Semantics.
//   • No billable APIs: distance is client-side haversine, Directions hands
//     off to the maps app.
//   • Colour comes from ChatColors: the same widget in both themes, re-toned,
//     never branched on brightness. The map takes the theme's style.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'primitives.dart';
import '../theme/app_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/post_model.dart';
import '../theme/tokens.dart';
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
    final c = ChatColors.of(context);

    final onMyWay = _IntentRow(
      icon: AppIcons.route,
      color: c.accentText,
      title: 'On my way',
      subtitle: 'Share your journey to this job',
      onTap: () {
        Navigator.pop(context);
        onOnMyWay();
      },
    );
    final sendPlace = _IntentRow(
      icon: AppIcons.location,
      color: c.success,
      title: 'Send a place',
      subtitle: 'Drop a pin — the gate, the building, the exact spot',
      onTap: () {
        Navigator.pop(context);
        onSendPlace();
      },
    );
    final request = _IntentRow(
      icon: AppIcons.locationConfirmed,
      color: c.accentText,
      title: 'Request location',
      subtitle: 'Ask them to share where to go',
      onTap: () {
        Navigator.pop(context);
        onRequestLocation();
      },
    );

    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.of(context).surface,
      shape: const RoundedRectangleBorder(
        borderRadius: AppRadius.sheetTop,
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SheetHandle(),
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
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.mdAll,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            IconBadge(icon, color: color),
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
                      color: c.contentPrimary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12.5, color: c.contentSecondary),
                  ),
                ],
              ),
            ),
            Icon(AppIcons.disclosure, size: 20, color: c.contentTertiary),
          ],
        ),
      ),
    );
  }
}

// _SheetGrabber was a third name for the drag handle, next to chat_ui's
// SheetHandle and fourteen inline copies. It is the primitive now.

// ── Map thumbnail ────────────────────────────────────────────────────────────

/// Static lite-mode map preview for thread cards, in the theme's map style
/// (standard on light, night on dark — [ChatColors.mapStyle]).
/// AbsorbPointer: without it the native map view claims the tap in the gesture
/// arena and the enclosing GestureDetector (open full screen) never fires.
class MapThumbnail extends StatelessWidget {
  final double latitude;
  final double longitude;

  const MapThumbnail({super.key, required this.latitude, required this.longitude});

  /// Stands in for the native map where no platform view can exist — the
  /// widget tests that render the chat for screenshots and layout checks.
  @visibleForTesting
  static Widget Function(BuildContext context, double latitude, double longitude)?
      debugBuilder;

  @override
  Widget build(BuildContext context) {
    final stand = debugBuilder;
    if (stand != null) return stand(context, latitude, longitude);
    return AbsorbPointer(
      child: GoogleMap(
        // Keyed by style: a lite-mode map is a bitmap rendered once, so a
        // theme switch must build a new one rather than restyle the old.
        key: ValueKey(ChatColors.of(context).mapStyle == null ? 'map-std' : 'map-night'),
        initialCameraPosition: CameraPosition(
          target: LatLng(latitude, longitude),
          zoom: 15,
        ),
        style: ChatColors.of(context).mapStyle,
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

/// Directions to a pin: Google Maps' directions screen when the app is
/// installed, otherwise the phone's default maps app on the pin (geo:), and
/// the web as the last resort.
Future<void> launchDirections(double lat, double lng, {String label = ''}) async {
  final directions = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=$lat%2C$lng&travelmode=driving');
  try {
    if (await launchUrl(directions, mode: LaunchMode.externalNonBrowserApplication)) return;
  } catch (_) {
    // No app claims the link; fall through to the default maps app.
  }
  final name = label.trim().isEmpty ? 'Shared location' : label.trim();
  final geo = Uri.parse('geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(name)})');
  try {
    if (await canLaunchUrl(geo) && await launchUrl(geo)) return;
  } catch (_) {}
  await launchUrl(directions, mode: LaunchMode.externalApplication);
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
    final color = ChatColors.of(context).successBar;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
    final dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
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
                color: color.withValues(alpha: 0.35 * (1 - _pulse.value)),
              ),
            ),
          ),
          dot,
        ],
      ),
    );
  }
}

// ── Journey card ─────────────────────────────────────────────────────────────

/// A journey in the thread. Three states:
///   live     → thumbnail + LIVE + "since HH:mm" (+ Stop / I've arrived for the sharer)
///   arrived  → mapless receipt: ✓ Arrived · HH:mm (the thread now shows an
///              arrived journey as an event pill; the receipt is kept for any
///              host that renders the card directly)
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

  /// The width the card lays itself out to — the bubble's inner width.
  final double width;

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
    this.width = 240,
  });

  @override
  Widget build(BuildContext context) {
    final c = ChatColors.of(context);
    final mine = message.isMe;
    final titleColor = mine ? c.onOutgoing : c.text;
    final subColor = mine ? c.onOutgoingMuted : c.textSecondary;

    // ── Arrived receipt — the journey's permanent conclusion in the thread ──
    if (message.isJourneyArrived) {
      final at = message.liveUntil ?? message.timestamp;
      // Journey duration comes free from the row: the message timestamp is the
      // moment sharing began and live_until is the moment it concluded. It
      // costs nothing and is exactly the detail that makes the receipt read as
      // a record of work done rather than a status line.
      final elapsed = at.difference(message.timestamp);
      final durationText = (elapsed.inMinutes >= 1 && elapsed.inHours < 12)
          ? (elapsed.inMinutes < 60
              ? '${elapsed.inMinutes} min journey'
              : '${elapsed.inHours} h ${elapsed.inMinutes % 60} min journey')
          : null;
      return Semantics(
        label: 'Journey completed. Arrived at ${_clockTime(context, at)}.'
            '${durationText == null ? '' : ' $durationText.'}',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: c.successTile, shape: BoxShape.circle),
              child: Icon(AppIcons.check, size: 20, color: c.success),
            ),
            const SizedBox(width: 11),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Arrived',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: titleColor)),
                  const SizedBox(height: 1),
                  Text(
                    [_clockTime(context, at), if (durationText != null) durationText].join(' · '),
                    style: TextStyle(fontSize: 12, color: subColor),
                  ),
                ],
              ),
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
              Icon(AppIcons.locationOff, size: 17, color: subColor),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Journey ended',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: titleColor)),
                    Text('Location no longer shared', style: TextStyle(fontSize: 12, color: subColor)),
                  ],
                ),
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
    // A map is invisible to a screen reader, so the ETA and remaining distance
    // — the two things this card exists to communicate — must be spoken, in
    // words rather than the abbreviations the visual line uses.
    final String spokenEta = eta == null
        ? ''
        : ' ${eta.replaceAll('min', 'minutes').replaceAll(' h ', ' hours ')}.';
    final String spokenRemaining = remaining == null
        ? ''
        : ' ${remaining.replaceAll(' m ', ' metres ').replaceAll(' km ', ' kilometres ')}.';
    return Semantics(
      label:
          'Live journey: $semanticsPhase$spokenEta$spokenRemaining'
          '${spokenRemaining.isEmpty && distance != null && !mine ? ' $distance.' : ''}'
          ' Sharing since ${_clockTime(context, message.timestamp)}. Double tap to open the live map.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onTap,
            child: ClipRRect(
              borderRadius: AppRadius.mdAll,
              child: SizedBox(
                width: width,
                height: width * 124 / 240,
                child: MapThumbnail(latitude: lat, longitude: lng),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: width,
            child: Row(
              children: [
                if (reconnecting)
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                  )
                else
                  const LiveDot(size: 7),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Hierarchy: once an ETA exists it becomes the headline
                      // and "On my way" drops to the supporting line. The ETA
                      // is the one fact the reader is looking for; making them
                      // find it in 12 pt secondary text buried the answer.
                      Text(eta ?? title,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: titleColor)),
                      // Deliberately NOT crossfaded. A switcher overlays the
                      // outgoing and incoming strings, and two different-width
                      // status lines ("Almost there…" → "2 min away · 480 m
                      // remaining") render on top of each other mid-transition
                      // as garbled text — observed on device. An ETA that
                      // changes at most once a minute does not need animating;
                      // clarity wins over polish here.
                      Text(
                        // With the ETA promoted, the supporting line carries
                        // the journey label plus remaining distance; without
                        // one it keeps the full Phase 2 status line verbatim.
                        eta == null
                            ? statusLine
                            : [title, if (remaining != null) remaining].join(' · '),
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
              width: width,
              child: Row(
                children: [
                  // 44 dp: these are pressed mid-journey, often one-handed and
                  // in motion. "I've arrived" also stays visually dominant over
                  // "Stop" — arriving is the expected outcome, stopping is the
                  // exception, and the hierarchy should say so.
                  Expanded(
                    child: SizedBox(
                      height: ChatGeometry.minTouch,
                      child: FilledButton.icon(
                        onPressed: onArrived == null
                            ? null
                            : () {
                                HapticFeedback.selectionClick();
                                onArrived!();
                              },
                        icon: const Icon(AppIcons.check, size: 17),
                        label: const Text("I've arrived"),
                        style: FilledButton.styleFrom(
                          backgroundColor: mine ? c.quoteOnOutgoing : c.accent,
                          foregroundColor: mine ? c.onOutgoing : c.onAccent,
                          padding: EdgeInsets.zero,
                          textStyle: const TextStyle(
                              fontFamily: AppTypeScale.family, fontSize: 13.5, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: ChatGeometry.minTouch,
                    child: TextButton(
                      onPressed: onStop,
                      style: TextButton.styleFrom(
                        foregroundColor: mine ? c.onOutgoingMuted : c.danger,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        textStyle: const TextStyle(
                            fontFamily: AppTypeScale.family, fontSize: 13, fontWeight: FontWeight.w600),
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
    final c = ChatColors.of(context);
    final mine = widget.message.isMe;
    final name = widget.partnerName.trim().isEmpty ? 'They' : widget.partnerName.trim();
    final titleColor = mine ? c.onOutgoing : c.text;
    final subColor = mine ? c.onOutgoingMuted : c.textSecondary;

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
                  color: mine ? c.quoteOnOutgoing : c.warningTile,
                  shape: BoxShape.circle,
                ),
                child: Icon(AppIcons.locationConfirmed,
                    size: 16, color: mine ? c.onOutgoing : c.accentText),
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
            Wrap(
              spacing: 8,
              children: [
                SizedBox(
                  // 44 dp — the responder's two choices must be comfortably
                  // tappable; 32 sat below every accessible-target guideline.
                  height: ChatGeometry.minTouch,
                  child: FilledButton(
                    onPressed: widget.onShareNow,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accent,
                      foregroundColor: c.onAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      textStyle: const TextStyle(
                          fontFamily: AppTypeScale.family, fontSize: 13, fontWeight: FontWeight.w700),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Share now'),
                  ),
                ),
                SizedBox(
                  height: ChatGeometry.minTouch,
                  child: TextButton(
                    onPressed: () => setState(() => _deferred = true),
                    style: TextButton.styleFrom(
                      foregroundColor: subColor,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      textStyle: const TextStyle(
                          fontFamily: AppTypeScale.family, fontSize: 13, fontWeight: FontWeight.w600),
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

// ── Context action + journey status strip ────────────────────────────────────

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
    final c = ChatColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(ChatGeometry.sidePadding, 6, ChatGeometry.sidePadding, 0),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: c.warningTile,
            borderRadius: AppRadius.pillAll,
            child: InkWell(
              borderRadius: AppRadius.pillAll,
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: ChatGeometry.minTouch),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 16, color: c.accentText),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: c.accentText),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact persistent strip under the pinned bar while a journey is active.
/// Lightweight by design: one line, LIVE pill, Stop only for the sharer.
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
    final c = ChatColors.of(context);
    final arrived = phase == JourneyPhase.arrived;
    final reconnecting = phase == JourneyPhase.reconnecting;
    final tint = reconnecting ? c.warningTile : c.successTile;
    final accent = reconnecting ? c.accentText : c.success;
    return Semantics(
      label: '$title.'
          '${arrived ? ' Journey completed.' : reconnecting ? ' Reconnecting.' : ' Live journey.'}'
          '${onStop != null ? ' Stop sharing button available.' : ' Double tap to open the live map.'}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Material(
          color: c.surfaceRaised,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.jobBarRadius)),
            side: BorderSide(color: c.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: ChatGeometry.minTouch),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: tint,
                        borderRadius: const BorderRadius.all(Radius.circular(ChatGeometry.jobTileRadius)),
                      ),
                      child: Icon(arrived ? AppIcons.check : AppIcons.route, size: 15, color: accent),
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
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.text),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (subtitle != null && subtitle!.isNotEmpty)
                            Text(
                              subtitle!,
                              style: TextStyle(fontSize: 11.5, color: c.textSecondary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (arrived)
                      Icon(AppIcons.successFilled, size: 15, color: c.success)
                    else if (reconnecting) ...[
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(color: c.accentText, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'RECONNECTING',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          color: c.accentText,
                        ),
                      ),
                    ] else ...[
                      const LiveDot(size: 6),
                      const SizedBox(width: 4),
                      Text(
                        'LIVE',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          color: c.success,
                        ),
                      ),
                    ],
                    if (onStop != null) ...[
                      const SizedBox(width: 6),
                      SizedBox(
                        height: ChatGeometry.minTouch,
                        child: TextButton(
                          onPressed: onStop,
                          style: TextButton.styleFrom(
                            foregroundColor: c.danger,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(
                                fontFamily: AppTypeScale.family, fontSize: 12.5, fontWeight: FontWeight.w700),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Stop sharing'),
                        ),
                      ),
                    ] else
                      Icon(AppIcons.disclosure, size: 18, color: c.textSecondary),
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
