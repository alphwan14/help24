// ─────────────────────────────────────────────────────────────────────────────
// Journey Confirmation — "On my way" (Location Experience, Phase 1).
//
// The user is travelling to a place the system already knows (the post's job
// location), so there is exactly ONE decision here: Start. No durations, no
// technical questions — the journey ends manually in Phase 1 (auto-arrival is
// Phase 2) with a silent 2-hour safety cap upstream.
//
// Permission panel (mandatory Scenario A): denial is a scenario, not an error.
//   • [Allow Location] requests; if permanently denied it opens app settings
//     and re-checks on resume — never an endless prompt loop, never a crash.
//   • [Not now] simply leaves. The journey cannot start without permission.
//
// Pops `true` when the user starts the journey; the chat screen owns the
// actual sharing lifecycle (single owner for stream/timers).
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:iconsax/iconsax.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../services/location_service.dart';
import '../services/place_name_cache.dart';
import '../theme/app_theme.dart';

class JourneyConfirmScreen extends StatefulWidget {
  /// The job location from the post; null when the post has no coordinates —
  /// the journey still works, it just has no destination pin to show.
  final LatLng? destination;
  final String destinationTitle;
  /// Human area text from the post (e.g. "Bamburi, Mombasa").
  final String destinationSubtitle;

  const JourneyConfirmScreen({
    super.key,
    this.destination,
    this.destinationTitle = 'This job',
    this.destinationSubtitle = '',
  });

  @override
  State<JourneyConfirmScreen> createState() => _JourneyConfirmScreenState();
}

/// One line of pre-journey reassurance: an icon and a short statement. Two of
/// these replace a paragraph — the reader scans them, which is the point.
class _ReassuranceRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isDark;

  const _ReassuranceRow({
    required this.icon,
    required this.text,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 15, color: color),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 13, height: 1.3, color: color),
          ),
        ),
      ],
    );
  }
}

class _JourneyConfirmScreenState extends State<JourneyConfirmScreen>
    with WidgetsBindingObserver {
  static const _fallbackRegion = CameraPosition(target: LatLng(-1.286389, 36.817223), zoom: 11.5);

  GoogleMapController? _map;
  bool _hasPermission = false;
  bool _checkedOnce = false;
  bool _requesting = false;
  LatLng? _myPos;

  /// Reverse-geocoded area name for the destination ("Mtopanga"), shown when
  /// the post carries no written location. Resolved once and cached process-
  /// wide; never blocks the screen — the map and CTA render regardless.
  String? _areaName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermission();
    _resolveAreaName();
  }

  Future<void> _resolveAreaName() async {
    final dest = widget.destination;
    // Only worth a lookup when there is no human location text already.
    if (dest == null || widget.destinationSubtitle.trim().isNotEmpty) return;
    final cached = PlaceNameCache.peek(dest.latitude, dest.longitude);
    if (cached != null) {
      setState(() => _areaName = cached);
      return;
    }
    final name = await PlaceNameCache.resolve(dest.latitude, dest.longitude);
    if (mounted && name != null) setState(() => _areaName = name);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check after the user returns from system Settings (permanently-denied path).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPermission();
  }

  Future<void> _refreshPermission() async {
    final has = await LocationService.hasPermission();
    if (!mounted) return;
    setState(() {
      _hasPermission = has;
      _checkedOnce = true;
    });
    if (has && _myPos == null) {
      final pos = await LocationService.getCurrentPosition(requestIfNeeded: false);
      if (!mounted || pos == null) return;
      setState(() => _myPos = LatLng(pos.latitude, pos.longitude));
      _fitCamera();
    }
  }

  Future<void> _allowPressed() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final status = await ph.Permission.locationWhenInUse.status;
    if (status.isPermanentlyDenied) {
      // The system dialog can no longer appear — Settings is the only path.
      await ph.openAppSettings();
    } else {
      await LocationService.requestPermission();
    }
    if (!mounted) return;
    setState(() => _requesting = false);
    await _refreshPermission();
  }

  void _fitCamera() {
    final dest = widget.destination;
    final me = _myPos;
    if (_map == null) return;
    if (dest != null && me != null) {
      final bounds = LatLngBounds(
        southwest: LatLng(
          dest.latitude < me.latitude ? dest.latitude : me.latitude,
          dest.longitude < me.longitude ? dest.longitude : me.longitude,
        ),
        northeast: LatLng(
          dest.latitude > me.latitude ? dest.latitude : me.latitude,
          dest.longitude > me.longitude ? dest.longitude : me.longitude,
        ),
      );
      _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 72));
    } else if (me != null && dest == null) {
      _map!.animateCamera(CameraUpdate.newLatLngZoom(me, 15));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final dest = widget.destination;
    final initial = dest != null
        ? CameraPosition(target: dest, zoom: 14.5)
        : (_myPos != null ? CameraPosition(target: _myPos!, zoom: 14.5) : _fallbackRegion);

    return Scaffold(
      appBar: AppBar(title: const Text('On my way')),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: initial,
            onMapCreated: (c) {
              _map = c;
              _fitCamera();
            },
            markers: {
              if (dest != null)
                Marker(
                  markerId: const MarkerId('destination'),
                  position: dest,
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                ),
            },
            myLocationEnabled: _hasPermission,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            padding: const EdgeInsets.only(bottom: 200),
          ),

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
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: SafeArea(
                top: false,
                child: !_checkedOnce
                    ? const SizedBox(
                        height: 80,
                        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : _hasPermission
                        ? _buildConfirm(isDark)
                        : _buildPermissionPanel(isDark),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Scenario A — the inline permission panel. No crash, no prompt loop.
  Widget _buildPermissionPanel(bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.primaryAccent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Iconsax.gps, color: AppTheme.primaryAccent, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Location access is required to share your journey.',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 46,
                child: FilledButton(
                  onPressed: _requesting ? null : _allowPressed,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primaryAccent,
                    foregroundColor: Colors.white,
                    textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _requesting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Allow location'),
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              height: 46,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(
                  foregroundColor:
                      isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  textStyle: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: const Text('Not now'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConfirm(bool isDark) {
    final hasDest = widget.destination != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Iconsax.flag, color: AppTheme.successGreen, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Names the row before naming the place: without it the
                  // title reads as "some text" rather than "where I'm going".
                  Text(
                    hasDest ? 'DESTINATION' : 'SHARING WITH',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: isDark
                          ? AppTheme.darkTextTertiary
                          : AppTheme.lightTextTertiary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.destinationTitle,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.destinationSubtitle.isEmpty && _areaName != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _areaName!,
                        style: TextStyle(
                          fontSize: 13,
                          color: isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary,
                        ),
                      ),
                    ),
                  if (widget.destinationSubtitle.isNotEmpty)
                    Text(
                      widget.destinationSubtitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Two short lines instead of one long sentence: what happens, then who
        // can see it. Sharing your live position is the most sensitive thing
        // this app asks for, and the scope answer ("only this chat") belongs
        // next to the button, not buried in a paragraph.
        _ReassuranceRow(
          icon: Iconsax.location,
          text: hasDest
              ? "Your live location is shared while you travel to this job"
              : 'Your live location is shared in this chat',
          isDark: isDark,
        ),
        const SizedBox(height: 7),
        _ReassuranceRow(
          icon: Iconsax.lock_1,
          text: 'Only this chat can see it — stop anytime',
          isDark: isDark,
        ),
        const SizedBox(height: 16),
        SizedBox(
          // 54: this is the screen's single decision, so it carries the weight
          // a primary CTA does in a navigation app rather than sitting at the
          // same height as an ordinary form button.
          height: 54,
          child: FilledButton.icon(
            onPressed: () {
              HapticFeedback.mediumImpact();
              Navigator.of(context).pop(true);
            },
            icon: const Icon(Iconsax.routing_2, size: 20),
            label: const Text('Start journey'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primaryAccent,
              foregroundColor: Colors.white,
              textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            ),
          ),
        ),
      ],
    );
  }
}
