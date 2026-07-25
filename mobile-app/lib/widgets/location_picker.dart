// ─────────────────────────────────────────────────────────────────────────────
// Location Picker — the ONE way a location is chosen anywhere in Help24.
//
// Replaces two Material DropdownButtons (city, then area) that between them
// offered 17 towns and could not be searched. This is the Uber/Bolt shape
// instead: a search field that answers as you type, your current location as
// the first and biggest option, the places you used last, the towns nearest to
// you, and only then the full A–Z list of every city, county headquarters and
// major town in the country.
//
// INVARIANTS
//   • Opens INSTANTLY. Every read is synchronous off LocationRegistry, which
//     serves the bundled dataset when nothing else has loaded yet.
//   • GPS is an OPTION, never a requirement. Every failure mode degrades to the
//     manual list with a sentence explaining what happened — posting is never
//     blocked by a permission dialog, an airplane-mode phone or a cold GPS.
//   • Search runs on every keystroke with no debounce, because the index is
//     bucketed and memoised (see SearchIndex). A debounce would be latency we
//     do not need to add.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:iconsax/iconsax.dart';

import '../models/place.dart';
import '../services/current_location_service.dart';
import '../services/location_registry.dart';
import '../services/recent_locations_store.dart';
import '../theme/app_theme.dart';

/// Opens the picker. Resolves to the chosen location, or null if dismissed.
///
/// [deviceLatitude]/[deviceLongitude]: the last known device position, when the
/// caller already has one (LocationProvider). Used ONLY to show a "Nearest to
/// you" shortcut — it never triggers a permission prompt and never changes what
/// gets saved unless the user taps one of those rows.
Future<LocationSelection?> showLocationPicker(
  BuildContext context, {
  LocationSelection? current,
  double? deviceLatitude,
  double? deviceLongitude,
  String title = 'Where is this?',
  String? subtitle,
  bool allowAnywhere = false,
}) {
  return showModalBottomSheet<LocationSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LocationPickerSheet(
      current: current,
      deviceLatitude: deviceLatitude,
      deviceLongitude: deviceLongitude,
      title: title,
      subtitle: subtitle,
      allowAnywhere: allowAnywhere,
    ),
  );
}

/// Sentinel returned when the user picks "Anywhere" on a FILTER. A filter needs
/// to express "no location constraint", which is a different answer from "I did
/// not choose" (null) — so it gets its own value rather than an empty string
/// every call site would have to remember to check.
const LocationSelection kAnywhereLocation =
    LocationSelection(label: '', cityName: '');

class _LocationPickerSheet extends StatefulWidget {
  final LocationSelection? current;
  final double? deviceLatitude;
  final double? deviceLongitude;
  final String title;
  final String? subtitle;
  final bool allowAnywhere;

  const _LocationPickerSheet({
    this.current,
    this.deviceLatitude,
    this.deviceLongitude,
    required this.title,
    this.subtitle,
    required this.allowAnywhere,
  });

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  final _searchController = TextEditingController();
  final _registry = LocationRegistry.instance;

  String _query = '';
  bool _locating = false;
  String? _locationError;
  bool _errorIsBlocked = false;
  List<LocationSelection> _recents = RecentLocationsStore.instance.cached;

  @override
  void initState() {
    super.initState();
    // The bundled dataset is enough to render everything; the server refresh is
    // a freshness optimisation that lands whenever it lands.
    _registry.ensureBundled().then((_) {
      if (mounted) setState(() {});
    });
    _registry.warmUp().then((_) {
      if (mounted) setState(() {});
    });
    RecentLocationsStore.instance.load().then((list) {
      if (mounted) setState(() => _recents = list);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    final next = value.trim();
    if (next == _query) return;
    setState(() => _query = next);
  }

  Future<void> _pick(LocationSelection selection) async {
    HapticFeedback.selectionClick();
    // Fire-and-forget: recording a recent must never delay the sheet closing.
    RecentLocationsStore.instance.add(selection);
    if (mounted) Navigator.of(context).pop(selection);
  }

  Future<void> _useCurrentLocation() async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _locationError = null;
      _errorIsBlocked = false;
    });
    final result = await CurrentLocationService.resolve();
    if (!mounted) return;
    if (result.isSuccess) {
      setState(() => _locating = false);
      await _pick(result.selection!);
      return;
    }
    setState(() {
      _locating = false;
      _locationError = result.message;
      _errorIsBlocked = result.failure == CurrentLocationFailure.permissionBlocked;
    });
  }

  bool get _hasDevicePosition =>
      widget.deviceLatitude != null && widget.deviceLongitude != null;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? AppTheme.darkSurface : AppTheme.lightSurface;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.55,
      maxChildSize: 0.96,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            _Grabber(isDark: isDark),
            _Header(
              title: widget.title,
              subtitle: widget.subtitle,
              isDark: isDark,
              onAnywhere: widget.allowAnywhere
                  ? () => Navigator.of(context).pop(kAnywhereLocation)
                  : null,
            ),
            _SearchField(
              controller: _searchController,
              isDark: isDark,
              onChanged: _onQueryChanged,
              onClear: () {
                _searchController.clear();
                _onQueryChanged('');
              },
            ),
            const SizedBox(height: 4),
            Expanded(
              child: _query.isEmpty
                  ? _buildBrowse(scrollController, isDark)
                  : _buildResults(scrollController, isDark),
            ),
          ],
        ),
      ),
    );
  }

  // ── Browse (no query) ──────────────────────────────────────────────────────

  Widget _buildBrowse(ScrollController controller, bool isDark) {
    final rows = _registry.browseRows;
    final nearby = _hasDevicePosition
        ? _registry.nearbyPlaces(widget.deviceLatitude!, widget.deviceLongitude!, limit: 4)
        : const <Place>[];

    // A single flat builder over three logical sections. Header widgets are
    // cheap and the A–Z rows are precomputed, so scrolling 479 entries costs
    // the same as scrolling 17 did.
    final leading = <Widget>[
      _CurrentLocationTile(
        isDark: isDark,
        busy: _locating,
        onTap: _useCurrentLocation,
      ),
      if (_locationError != null)
        _InlineNotice(
          message: _locationError!,
          isDark: isDark,
          actionLabel: _errorIsBlocked ? 'Open settings' : null,
          onAction: _errorIsBlocked ? CurrentLocationService.openSettings : null,
        ),
      if (_recents.isNotEmpty) ...[
        _SectionLabel(text: 'Recent', isDark: isDark),
        for (final r in _recents)
          _LocationTile(
            title: r.label,
            subtitle: r.isFromDevice ? 'Used recently · from your location' : 'Used recently',
            icon: Iconsax.clock,
            isDark: isDark,
            selected: widget.current?.label == r.label,
            onTap: () => _pick(r),
          ),
      ],
      if (nearby.isNotEmpty) ...[
        _SectionLabel(text: 'Nearest to you', isDark: isDark),
        for (final p in nearby)
          _LocationTile(
            title: p.storageLabel,
            subtitle: _distanceSubtitle(p),
            icon: Iconsax.gps,
            isDark: isDark,
            selected: widget.current?.placeId == p.id,
            onTap: () => _pick(_registry.selectionFor(p)),
          ),
      ],
      _SectionLabel(text: 'All locations', isDark: isDark),
    ];

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 28),
      // itemCount is O(1): the A–Z rows were built once when the dataset loaded.
      itemCount: leading.length + rows.length,
      itemBuilder: (context, index) {
        if (index < leading.length) return leading[index];
        final row = rows[index - leading.length];
        if (row.isHeader) return _AlphabetHeader(letter: row.header!, isDark: isDark);
        final place = row.place!;
        return _LocationTile(
          title: place.storageLabel,
          subtitle: place.subtitle,
          icon: _iconFor(place),
          isDark: isDark,
          selected: widget.current?.placeId == place.id,
          onTap: () => _pick(_registry.selectionFor(place)),
        );
      },
    );
  }

  String _distanceSubtitle(Place p) {
    final km = _registry.distanceKmTo(p, widget.deviceLatitude!, widget.deviceLongitude!);
    if (km == null) return p.subtitle;
    final distance = km < 1 ? '${(km * 1000).round()} m away' : '${km.toStringAsFixed(km < 10 ? 1 : 0)} km away';
    return '$distance · ${p.county} County';
  }

  // ── Results (query) ────────────────────────────────────────────────────────

  Widget _buildResults(ScrollController controller, bool isDark) {
    final results = _registry.search(_query);
    if (results.isEmpty) {
      return _EmptyResults(query: _query, isDark: isDark);
    }
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.only(bottom: 28),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final place = results[index];
        return _LocationTile(
          title: place.storageLabel,
          subtitle: place.subtitle,
          icon: _iconFor(place),
          isDark: isDark,
          selected: widget.current?.placeId == place.id,
          highlight: _query,
          onTap: () => _pick(_registry.selectionFor(place)),
        );
      },
    );
  }

  IconData _iconFor(Place p) => switch (p.kind) {
        PlaceKind.city => Iconsax.building_4,
        PlaceKind.area => Iconsax.map_1,
        PlaceKind.town => Iconsax.location,
      };
}

// ── Pieces ───────────────────────────────────────────────────────────────────

class _Grabber extends StatelessWidget {
  final bool isDark;
  const _Grabber({required this.isDark});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 8),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}

class _Header extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool isDark;
  final VoidCallback? onAnywhere;

  const _Header({
    required this.title,
    this.subtitle,
    required this.isDark,
    this.onAnywhere,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          if (onAnywhere != null)
            TextButton(
              onPressed: onAnywhere,
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primaryAccent,
                textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
              ),
              child: const Text('Anywhere'),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final bool isDark;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchField({
    required this.controller,
    required this.isDark,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search city, town or estate',
          prefixIcon: const Icon(Iconsax.search_normal_1, size: 18),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Clear search',
                    onPressed: onClear,
                  ),
          ),
          filled: true,
          fillColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// The hero row. Deliberately the largest, most colourful thing on the screen:
/// for most posts it is the correct answer and should take one tap, not a
/// search. It also carries its own busy state so the sheet never blocks.
class _CurrentLocationTile extends StatelessWidget {
  final bool isDark;
  final bool busy;
  final VoidCallback onTap;

  const _CurrentLocationTile({
    required this.isDark,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Semantics(
        button: true,
        label: 'Use my current location',
        child: Material(
          color: AppTheme.primaryAccent.withValues(alpha: isDark ? 0.16 : 0.10),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: busy ? null : onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryAccent.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: busy
                        ? const Padding(
                            padding: EdgeInsets.all(11),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.primaryAccent,
                            ),
                          )
                        : const Icon(Iconsax.gps, size: 20, color: AppTheme.primaryAccent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          busy ? 'Finding your location…' : 'Use current location',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.primaryAccent,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          busy
                              ? 'This takes a moment outdoors'
                              : 'We\'ll name the spot you\'re standing in',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: isDark
                                ? AppTheme.darkTextSecondary
                                : AppTheme.lightTextSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!busy)
                    const Icon(Icons.chevron_right_rounded,
                        size: 20, color: AppTheme.primaryAccent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  final String message;
  final bool isDark;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _InlineNotice({
    required this.message,
    required this.isDark,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: AppTheme.warningOrange.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded,
                size: 17, color: AppTheme.warningOrange),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 12.5, color: AppTheme.warningOrange),
              ),
            ),
            if (actionLabel != null)
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.warningOrange,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(actionLabel!),
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final bool isDark;
  const _SectionLabel({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
        child: Text(
          text.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.9,
            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
          ),
        ),
      );
}

class _AlphabetHeader extends StatelessWidget {
  final String letter;
  final bool isDark;
  const _AlphabetHeader({required this.letter, required this.isDark});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        color: (isDark ? AppTheme.darkCard : AppTheme.lightCard)
            .withValues(alpha: isDark ? 0.6 : 0.7),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
        child: Text(
          letter,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
          ),
        ),
      );
}

class _LocationTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isDark;
  final bool selected;
  final String? highlight;
  final VoidCallback onTap;

  const _LocationTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isDark,
    required this.selected,
    required this.onTap,
    this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    final primary = isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final secondary = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(
          children: [
            Icon(icon, size: 18, color: selected ? AppTheme.primaryAccent : secondary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HighlightedText(
                    text: title,
                    query: highlight,
                    baseStyle: TextStyle(
                      fontSize: 14.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? AppTheme.primaryAccent : primary,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: secondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle_rounded,
                  size: 18, color: AppTheme.primaryAccent),
          ],
        ),
      ),
    );
  }
}

/// Bolds the matched span so the reason a result is in the list is visible at a
/// glance. Case-insensitive, first match only — a second highlight in the same
/// short label reads as noise rather than help.
class _HighlightedText extends StatelessWidget {
  final String text;
  final String? query;
  final TextStyle baseStyle;

  const _HighlightedText({
    required this.text,
    required this.query,
    required this.baseStyle,
  });

  @override
  Widget build(BuildContext context) {
    final q = query?.trim().toLowerCase() ?? '';
    if (q.isEmpty) {
      return Text(text, style: baseStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final index = text.toLowerCase().indexOf(q);
    if (index < 0) {
      return Text(text, style: baseStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: text.substring(0, index)),
          TextSpan(
            text: text.substring(index, index + q.length),
            style: baseStyle.copyWith(
              fontWeight: FontWeight.w800,
              color: AppTheme.primaryAccent,
            ),
          ),
          TextSpan(text: text.substring(index + q.length)),
        ],
      ),
    );
  }
}

class _EmptyResults extends StatelessWidget {
  final String query;
  final bool isDark;
  const _EmptyResults({required this.query, required this.isDark});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Iconsax.search_normal_1,
                  size: 32,
                  color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
              const SizedBox(height: 14),
              Text(
                'No place matches "$query"',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                'Try the nearest bigger town, or use your current location.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
}
