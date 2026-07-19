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
import 'package:iconsax/iconsax.dart';

import '../services/location_service.dart';
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

class _PlacePickerScreenState extends State<PlacePickerScreen> {
  // Nairobi CBD — country-scale sensible default when nothing better exists.
  static const _fallbackRegion = CameraPosition(target: LatLng(-1.286389, 36.817223), zoom: 11.5);

  GoogleMapController? _map;
  late final TextEditingController _labelCtrl = TextEditingController(text: widget.initialLabel);

  late LatLng _center;
  late double _zoom;
  bool _hasPermission = false;
  bool _acquiring = false;
  // True once the user pans — after that we never yank the camera from under them.
  bool _userMoved = false;
  bool _programmaticMove = false;

  @override
  void initState() {
    super.initState();
    final start = widget.initialCenter ?? _fallbackRegion.target;
    _center = start;
    _zoom = widget.initialCenter != null ? 16 : _fallbackRegion.zoom;
    _warmUpPosition();
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
    Navigator.of(context).pop(PickedPlace(
      latitude: _center.latitude,
      longitude: _center.longitude,
      label: _labelCtrl.text.trim(),
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
            padding: const EdgeInsets.only(bottom: 148),
          ),

          // Fixed center pin. IgnorePointer so map gestures pass through.
          // Bottom-aligned to center: the pin TIP marks the picked spot.
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 148 + 46),
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

          // Scenario D: acquiring chip — informative, never blocking.
          if (_acquiring)
            Positioned(
              top: 12,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: surface.withValues(alpha: 0.95),
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
                          color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // My-position button — above the bottom card, outside the map surface.
          Positioned(
            right: 14,
            bottom: 164,
            child: FloatingActionButton.small(
              heroTag: 'place_picker_my_position',
              onPressed: _onMyPositionPressed,
              tooltip: 'My position',
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
                      height: 46,
                      child: FilledButton.icon(
                        onPressed: _confirm,
                        icon: const Icon(Iconsax.send_2, size: 18),
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
