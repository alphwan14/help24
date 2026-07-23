// ─────────────────────────────────────────────────────────────────────────────
// Place Picker — "Send a place" / "Pin on map" (Location Experience, Phase 1).
//
// Full-screen map with a FIXED CENTER PIN: the user drags the MAP, not the pin.
// Motor-friendlier than pin-dragging and immune to the platform-view gesture
// arena (the map legitimately owns every gesture here).
//
// GPS is OPTIONAL by design (mandatory fallback scenarios B & D):
//   • opens instantly on the passed center (job location) → last-known device
//     position → a sensible default region; never blocks on a GPS fix
//   • with permission granted, silently acquires the position and shows the
//     blue dot; recenters once only if the caller had no better start point
//   • the my-position button requests permission on demand; a denial degrades
//     to a quiet hint — manual pin placement always works
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:iconsax/iconsax.dart';

import '../services/location_service.dart';
import '../services/recent_places_store.dart';
import '../theme/app_theme.dart';
import '../widgets/location_experience.dart';

class PlacePickerScreen extends StatefulWidget {
  /// Best-known starting point (usually the post's job location). Null → last
  /// known device position → default region.
  final LatLng? initialCenter;
  final String title;
  final String confirmLabel;
  /// Seed for the label field (unused in Phase 1 flows, ready for edit flows).
  final String initialLabel;

  const PlacePickerScreen({
    super.key,
    this.initialCenter,
    this.title = 'Send a place',
    this.confirmLabel = 'Send place',
    this.initialLabel = '',
  });

  @override
  State<PlacePickerScreen> createState() => _PlacePickerScreenState();
}

/// Reserved search area — the ONLY thing that changes when Google Places is
/// enabled later.
///
/// FUTURE PLACES INTEGRATION (deliberately isolated)
/// This is a self-contained, non-interactive placeholder: it calls no API and
/// does not pretend to search (tapping it says so plainly). When the product
/// decides Places is worth the recurring cost, swap THIS widget for a Places
/// autocomplete field that, on selection, calls the same camera move the
/// recents row already uses (`_animateTo` + optional label). Nothing else on
/// the screen — map, centre pin, recents, label suggestions, current-location
/// flow, send logic — needs to change. That is why it lives here as one
/// replaceable widget rather than being woven into the layout.
class _ReservedSearchField extends StatelessWidget {
  final bool isDark;
  const _ReservedSearchField({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final fill = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final muted = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
    return Semantics(
      button: true,
      label: 'Search places, coming soon',
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(14),
        elevation: 2,
        shadowColor: Colors.black26,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            // Honest: no API, no fake results — just set expectations.
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(
                content: Text('Place search is coming soon. For now, move the map or pick a recent spot.'),
                behavior: SnackBarBehavior.floating,
                duration: Duration(seconds: 3),
              ));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Icon(Iconsax.search_normal_1, size: 18, color: muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Search places',
                    style: TextStyle(fontSize: 14.5, color: muted),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryAccent.withValues(alpha: isDark ? 0.20 : 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'Soon',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                      color: AppTheme.primaryAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontally-scrolling recent pinned places (device-only). One tap moves the
/// map to a place the user has pinned before — the free, zero-API alternative
/// to search for the spots people re-use most.
class _RecentPlacesRow extends StatelessWidget {
  final List<RecentPlace> recents;
  final bool isDark;
  final ValueChanged<RecentPlace> onSelect;

  const _RecentPlacesRow({
    required this.recents,
    required this.isDark,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 34,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: recents.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final p = recents[i];
            final text = p.label.isEmpty ? 'Pinned spot' : p.label;
            return Material(
              color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
              borderRadius: BorderRadius.circular(18),
              elevation: 1.5,
              shadowColor: Colors.black26,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => onSelect(p),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Iconsax.clock, size: 14, color: AppTheme.primaryAccent),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A tappable label idea. Suggestion only — the label field stays free-text.
class _SuggestionChip extends StatelessWidget {
  final String label;
  final bool isDark;
  final VoidCallback onTap;

  const _SuggestionChip({required this.label, required this.isDark, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // A horizontal ListView forces each item to the row's full height, so the
    // chip must CENTRE its text within that height rather than pad-from-top —
    // padding-from-top is what pushed the text down and clipped the lower half.
    return Material(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlacePickerScreenState extends State<PlacePickerScreen> {
  // Nairobi CBD — country-scale sensible default when nothing better exists.
  static const _fallbackRegion = CameraPosition(target: LatLng(-1.286389, 36.817223), zoom: 11.5);

  /// Height reserved for the bottom card (instruction + label + CTA + safe
  /// area). ONE constant on purpose: it feeds both the map's bottom padding —
  /// which is what makes Google's own chrome and the camera centre sit above
  /// the card — and the centre pin's offset. These were duplicated literals,
  /// and when the card grew they silently disagreed, which moves the pin tip
  /// off the true centre and makes the user pin a spot they did not choose.
  // Approximate rendered height of the bottom card: chip row + label field +
  // CTA + paddings + safe area. The "move the map" hint was moved out to a
  // floating pill, so the card is shorter than before and the map gets that
  // space back. Kept as ONE constant because it feeds BOTH the map's bottom
  // padding and the centre pin's offset; if they disagree the pin tip drifts
  // off the true map centre and the user pins a spot they did not choose.
  static const double _bottomCardHeight = 202;
  static const double _pinHeight = 46;

  /// Zero-cost, free-text label ideas. Suggestions only — the field accepts
  /// anything. These match how people actually describe a meeting point at a
  /// Kenyan address (a gate, a kiosk, a stage) far better than a bare pin.
  static const List<String> _labelSuggestions = [
    'Front Gate',
    'Main Entrance',
    'Reception',
    'Parking',
    'Apartment',
    'Office',
    'Shop Entrance',
    'Roadside Pickup',
  ];

  GoogleMapController? _map;
  late final TextEditingController _labelCtrl = TextEditingController(text: widget.initialLabel);

  late LatLng _center;
  late double _zoom;
  bool _hasPermission = false;
  bool _acquiring = false;
  // True once the user pans — after that we never yank the camera from under them.
  bool _userMoved = false;
  bool _programmaticMove = false;

  // Device-only recents (no backend, no API). Seeded from the sync cache so the
  // row can paint on first frame, then refreshed from disk.
  List<RecentPlace> _recents = RecentPlacesStore.cached;

  @override
  void initState() {
    super.initState();
    final start = widget.initialCenter ?? _fallbackRegion.target;
    _center = start;
    _zoom = widget.initialCenter != null ? 16 : _fallbackRegion.zoom;
    _warmUpPosition();
    _loadRecents();
  }

  Future<void> _loadRecents() async {
    final list = await RecentPlacesStore.load();
    if (mounted) setState(() => _recents = list);
  }

  void _selectRecent(RecentPlace place) {
    HapticFeedback.selectionClick();
    _userMoved = true; // an explicit choice — don't let GPS warm-up override it
    if (place.label.isNotEmpty) _labelCtrl.text = place.label;
    _animateTo(LatLng(place.latitude, place.longitude), 17);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    super.dispose();
  }

  /// Silent GPS warm-up: never prompts (requestIfNeeded: false), never blocks.
  Future<void> _warmUpPosition() async {
    final has = await LocationService.hasPermission();
    if (!mounted) return;
    setState(() {
      _hasPermission = has;
      _acquiring = has;
    });
    if (!has) return;
    final pos = await LocationService.getCurrentPosition(requestIfNeeded: false);
    if (!mounted) return;
    setState(() => _acquiring = false);
    // Recenter once, only when the caller had no job pin and the user hasn't
    // taken control of the camera yet.
    if (pos != null && widget.initialCenter == null && !_userMoved) {
      _animateTo(LatLng(pos.latitude, pos.longitude), 16);
    }
  }

  Future<void> _onMyPositionPressed() async {
    var has = await LocationService.hasPermission();
    if (!has) {
      has = await LocationService.requestPermission();
      if (!mounted) return;
      if (!has) {
        // Scenario B: denial is a scenario, not an error — pin placement works.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location is off — you can still place the pin by moving the map.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      setState(() => _hasPermission = true);
    }
    setState(() => _acquiring = true);
    final pos = await LocationService.getCurrentPosition(requestIfNeeded: false);
    if (!mounted) return;
    setState(() => _acquiring = false);
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not get a GPS fix. Move the map to place the pin.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    _animateTo(LatLng(pos.latitude, pos.longitude), 17);
  }

  void _animateTo(LatLng target, double zoom) {
    _programmaticMove = true;
    _map?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: zoom)));
  }

  void _confirm() {
    final label = _labelCtrl.text.trim();
    // Record locally as a recent spot (device-only). Fire-and-forget: it must
    // never delay or block returning the picked place.
    unawaited(RecentPlacesStore.add(
      latitude: _center.latitude,
      longitude: _center.longitude,
      label: label,
    ));
    Navigator.of(context).pop(PickedPlace(
      latitude: _center.latitude,
      longitude: _center.longitude,
      label: label,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _center, zoom: _zoom),
            onMapCreated: (c) => _map = c,
            onCameraMoveStarted: () {
              if (_programmaticMove) {
                _programmaticMove = false;
              } else {
                _userMoved = true;
              }
            },
            onCameraMove: (pos) => _center = pos.target,
            myLocationEnabled: _hasPermission,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            // Keep Google chrome clear of the bottom card.
            padding: const EdgeInsets.only(bottom: _bottomCardHeight),
          ),

          // Fixed center pin. IgnorePointer so map gestures pass through.
          // Bottom-aligned to center: the pin TIP marks the picked spot.
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: _bottomCardHeight + _pinHeight),
                child: Semantics(
                  label: 'Map pin. Drag the map to position the pin on the exact spot.',
                  child: const Icon(
                    Icons.location_pin,
                    size: 46,
                    color: AppTheme.errorRed,
                    shadows: [Shadow(color: Colors.black38, blurRadius: 8, offset: Offset(0, 2))],
                  ),
                ),
              ),
            ),
          ),

          // Contextual hint, floated just above the pin instead of taking a
          // permanent row in the bottom card — it frees that space for the map
          // and puts the guidance where the eye already is. Fades out once the
          // user starts panning; they've understood by then.
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: _bottomCardHeight + _pinHeight + 54),
                child: AnimatedOpacity(
                  opacity: _userMoved ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
                    ),
                    child: Text(
                      'Move the map to place the pin',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Top region: reserved search area + recents + acquiring hint ──
          // A single deterministic column so nothing overlaps regardless of
          // whether recents exist or GPS is acquiring.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ReservedSearchField(isDark: isDark),
                    if (_recents.isNotEmpty)
                      _RecentPlacesRow(
                        recents: _recents,
                        isDark: isDark,
                        onSelect: _selectRecent,
                      ),
                    if (_acquiring)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                            decoration: BoxDecoration(
                              color: surface.withValues(alpha: 0.96),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Finding your position…',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? AppTheme.darkTextSecondary
                                        : AppTheme.lightTextSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),

          // My-position button — above the bottom card, outside the map surface.
          // The single, clear "recenter on me" action (one tap, animates the
          // camera). A second recenter control would only compete with it.
          Positioned(
            right: 14,
            bottom: _bottomCardHeight + 8, // just above the card, never behind it
            child: FloatingActionButton.small(
              heroTag: 'place_picker_my_position',
              onPressed: _onMyPositionPressed,
              tooltip: 'Recenter on my location',
              backgroundColor: surface,
              foregroundColor: AppTheme.primaryAccent,
              child: const Icon(Iconsax.gps, size: 20),
            ),
          ),

          // Bottom card: label + confirm. Every action lives OUTSIDE the map.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 12)],
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Free-text label ideas. Tapping one fills the field; the
                    // user can still type anything. The row height must clear
                    // the chips' full height (they were being clipped in half)
                    // — the chip centres its own text, so this only needs to be
                    // tall enough not to crop the shadow/ink.
                    SizedBox(
                      height: 38,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        clipBehavior: Clip.none,
                        itemCount: _labelSuggestions.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 6),
                        itemBuilder: (context, i) {
                          final s = _labelSuggestions[i];
                          return _SuggestionChip(
                            label: s,
                            isDark: isDark,
                            onTap: () {
                              HapticFeedback.selectionClick();
                              _labelCtrl
                                ..text = s
                                ..selection = TextSelection.collapsed(offset: s.length);
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _labelCtrl,
                      textCapitalization: TextCapitalization.sentences,
                      maxLength: 60,
                      decoration: InputDecoration(
                        counterText: '',
                        prefixIcon: const Icon(Iconsax.location, size: 18),
                        hintText: 'Label this spot — “Black gate, next to kiosk” (optional)',
                        hintStyle: TextStyle(
                          fontSize: 13.5,
                          color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                        ),
                        filled: true,
                        fillColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      // Matches the journey confirm CTA: both are the single
                      // decision on their screen and should carry equal weight.
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: () {
                          HapticFeedback.mediumImpact();
                          _confirm();
                        },
                        icon: const Icon(Iconsax.send_2, size: 19),
                        label: Text(widget.confirmLabel),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.primaryAccent,
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
