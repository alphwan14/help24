import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/filter_selection.dart';
import '../models/place.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/location_provider.dart';
import '../services/filter_history_service.dart';
import '../theme/app_theme.dart';
import 'location_picker.dart';

/// The filter sheet.
///
/// RETURNS ITS ANSWER; it does not apply itself. `Navigator.pop` carries a
/// [FilterSelection] when the user searches and `null` when they leave — which
/// is the whole reason cancelling now costs nothing.
///
/// It used to mutate AppProvider through six setters, the first being
/// `clearFilters()`, which issued a full ranked feed request with the filters
/// emptied and the new ones not yet applied. The screen then issued a second
/// request unconditionally on close — including on cancel, which was measured
/// on the S20+ as a complete round trip and feed reinstall for a sheet the user
/// had dismissed without touching.
class FilterBottomSheet extends StatefulWidget {
  /// The scroll controller [DraggableScrollableSheet] hands its child.
  ///
  /// It used to be discarded — the sheet was built as `const FilterBottomSheet()`
  /// and scrolled with a controller of its own. A DraggableScrollableSheet
  /// resizes by watching THIS controller, so ignoring it meant the sheet could
  /// not be dragged from its content and the inner list scrolled independently
  /// of the box containing it. Passing it through is what makes the two one
  /// gesture again.
  final ScrollController? scrollController;

  const FilterBottomSheet({super.key, this.scrollController});

  @override
  State<FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<FilterBottomSheet> {
  late Set<String> _selectedCategories;
  late String _selectedCity;
  late String _selectedArea;
  late double _minPrice;
  late double _maxPrice;
  late Urgency? _selectedUrgency;

  /// The vocabulary a typed profession is resolved against: the registry plus
  /// every category name the feed has actually returned. Captured once so the
  /// suggestion list does not shift under the user's finger mid-type.
  late List<String> _vocabulary;

  late List<FilterSelection> _history;

  final _customCategoryController = TextEditingController();
  bool _showCustomCategoryInput = false;

  @override
  void initState() {
    super.initState();
    final provider = context.read<AppProvider>();
    final current = provider.filterSelection;
    _selectedCategories = Set<String>.from(current.categories);
    _selectedCity = current.city;
    _selectedArea = current.area;
    _minPrice = current.minPrice;
    _maxPrice = current.maxPrice;
    _selectedUrgency = current.urgency;
    _vocabulary = provider.knownCategoryNames.toList()..sort();
    // Read, not run. Opening the sheet shows what you have searched before; it
    // never executes one of them.
    //
    // Seeded synchronously from whatever is already in memory so a warm sheet
    // paints Recent on its first frame, then confirmed from disk — which is
    // what makes it work on a signed-out cold start, where nothing has had a
    // reason to load it yet.
    _history = FilterHistoryService.instance.entries;
    unawaited(provider.ensureFilterHistoryLoaded().then((_) {
      if (!mounted) return;
      final loaded = FilterHistoryService.instance.entries;
      if (loaded.length == _history.length) return;
      setState(() => _history = loaded);
    }));
  }

  @override
  void dispose() {
    _customCategoryController.dispose();
    super.dispose();
  }

  FilterSelection get _selection => FilterSelection(
        categories: _selectedCategories,
        city: _selectedCity,
        area: _selectedArea,
        minPrice: _minPrice,
        maxPrice: _maxPrice,
        urgency: _selectedUrgency,
      );

  /// Add whatever the user typed, resolved to a spelling the corpus can match.
  ///
  /// `posts.category` is matched exactly and case-sensitively on both sides, so
  /// sending "cleaning" when the rows say "Cleaning" returned nothing at all —
  /// verified against production: 'Cleaning' → 2 posts, 'cleaning' → 0.
  void _addCustomCategory([String? raw]) {
    final resolved = Category.resolveFilterName(
      raw ?? _customCategoryController.text,
      _vocabulary,
    );
    if (resolved == null) {
      // Not a usable service name (too short, too long, no letters). Say so
      // rather than silently accepting something that can only match nothing.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a service name of 3–40 letters')),
      );
      return;
    }
    setState(() {
      // Case-insensitive on the way in too, so tapping a suggestion that is
      // already selected cannot produce a near-duplicate chip.
      _selectedCategories
          .removeWhere((c) => c.toLowerCase() == resolved.toLowerCase());
      _selectedCategories.add(resolved);
      _customCategoryController.clear();
      _showCustomCategoryInput = false;
    });
  }

  void _restore(FilterSelection selection) {
    setState(() {
      _selectedCategories = Set<String>.from(selection.categories);
      _selectedCity = selection.city;
      _selectedArea = selection.area;
      _minPrice = selection.minPrice;
      _maxPrice = selection.maxPrice;
      _selectedUrgency = selection.urgency;
      _showCustomCategoryInput = false;
      _customCategoryController.clear();
    });
  }

  Future<void> _clearHistory() async {
    await FilterHistoryService.instance.clear();
    if (!mounted) return;
    setState(() => _history = FilterHistoryService.instance.entries);
  }

  /// The filter's location as one human string. Mirrors exactly what the
  /// provider matches against (`post.location` contains city AND area), so what
  /// the chip says and what the query does can never drift apart.
  String get _locationLabel {
    if (_selectedCity.isEmpty) return 'Anywhere';
    return _selectedArea.isEmpty ? _selectedCity : '$_selectedArea, $_selectedCity';
  }

  Future<void> _chooseLocation() async {
    final provider = context.read<LocationProvider>();
    final picked = await showLocationPicker(
      context,
      current: _selectedCity.isEmpty
          ? null
          : LocationSelection(
              label: _locationLabel,
              cityName: _selectedCity,
              areaName: _selectedArea.isEmpty ? null : _selectedArea,
            ),
      deviceLatitude: provider.latitude,
      deviceLongitude: provider.longitude,
      title: 'Filter by location',
      subtitle: 'Show only posts in one place.',
      allowAnywhere: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      // The "Anywhere" sentinel carries an empty label — that is the filter's
      // way of saying "no location constraint", which is a real answer.
      _selectedCity = picked.cityName;
      _selectedArea = picked.areaName ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final registryNames = {
      for (final c in Category.all) c.name.toLowerCase(),
    };
    // Custom professions the user has chosen (typed, or restored from history)
    // stay visible and deselectable even though no chip in the registry row
    // represents them.
    final customSelected = _selectedCategories
        .where((c) => !registryNames.contains(c.toLowerCase()))
        .toList()
      ..sort();

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Filters',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                TextButton(
                  // Clears the SELECTION being edited, not the feed and not the
                  // history. Nothing is applied until Search.
                  onPressed: () => _restore(FilterSelection.none),
                  child: Text(
                    'Clear All',
                    style: TextStyle(color: AppTheme.primaryAccent),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            // A visible thumb, because this is a long sheet: eight Recent chips,
            // thirty-odd categories, location, seven price bands and urgency.
            // Nothing here told the reader how far down they were or let them
            // move quickly — the list simply ran on.
            child: Scrollbar(
              controller: widget.scrollController,
              thumbVisibility: widget.scrollController != null,
              child: SingleChildScrollView(
                controller: widget.scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  // ── Recent ────────────────────────────────────────────────
                  if (_history.isNotEmpty) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Recent', style: Theme.of(context).textTheme.titleLarge),
                        TextButton(
                          onPressed: _clearHistory,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            'Clear history',
                            style: TextStyle(
                              fontSize: 13,
                              color: isDark
                                  ? AppTheme.darkTextTertiary
                                  : AppTheme.lightTextTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final entry in _history)
                          ActionChip(
                            avatar: Icon(
                              Iconsax.clock,
                              size: 15,
                              color: AppTheme.primaryAccent,
                            ),
                            label: Text(
                              entry.label,
                              style: const TextStyle(fontSize: 13),
                            ),
                            // Fills the sheet in. Applying is still Search —
                            // opening this sheet must never run a search by
                            // itself.
                            onPressed: () => _restore(entry),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                              side: BorderSide(
                                color: AppTheme.primaryAccent.withValues(alpha: 0.4),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],

                  // ── Category ──────────────────────────────────────────────
                  Text(
                    'Category',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ...Category.all.map((category) {
                        final isSelected = _selectedCategories.any(
                          (c) => c.toLowerCase() == category.name.toLowerCase(),
                        );
                        return FilterChip(
                          selected: isSelected,
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                category.icon,
                                size: 16,
                                color: isSelected
                                    ? AppTheme.primaryAccent
                                    : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                              ),
                              const SizedBox(width: 6),
                              Text(category.name),
                            ],
                          ),
                          onSelected: (selected) {
                            setState(() {
                              _selectedCategories.removeWhere((c) =>
                                  c.toLowerCase() == category.name.toLowerCase());
                              if (selected) {
                                _selectedCategories.add(category.name);
                              }
                            });
                          },
                          selectedColor: AppTheme.primaryAccent.withValues(alpha: 0.2),
                          checkmarkColor: AppTheme.primaryAccent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        );
                      }),
                      // Custom professions already chosen — not in the registry
                      // row, so they need their own removable chips or they
                      // could never be deselected.
                      ...customSelected.map((name) => FilterChip(
                            selected: true,
                            label: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.work_outline,
                                    size: 16, color: AppTheme.primaryAccent),
                                const SizedBox(width: 6),
                                Text(name),
                              ],
                            ),
                            onSelected: (_) => setState(
                                () => _selectedCategories.remove(name)),
                            selectedColor:
                                AppTheme.primaryAccent.withValues(alpha: 0.2),
                            checkmarkColor: AppTheme.primaryAccent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                            ),
                          )),
                      // Add custom category chip
                      if (!_showCustomCategoryInput)
                        ActionChip(
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.add,
                                size: 16,
                                color: AppTheme.primaryAccent,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Custom',
                                style: TextStyle(color: AppTheme.primaryAccent),
                              ),
                            ],
                          ),
                          onPressed: () {
                            setState(() {
                              _showCustomCategoryInput = true;
                            });
                          },
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                            side: BorderSide(color: AppTheme.primaryAccent),
                          ),
                        ),
                    ],
                  ),
                  // Custom category input
                  if (_showCustomCategoryInput) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customCategoryController,
                            // Focused on open: the field used to appear inert,
                            // and typing went nowhere until it was tapped.
                            autofocus: true,
                            textCapitalization: TextCapitalization.words,
                            decoration: const InputDecoration(
                              hintText: 'Enter a service — e.g. Nyama Choma',
                              contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) => _addCustomCategory(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _addCustomCategory,
                          icon: Icon(Icons.check_circle, color: AppTheme.successGreen),
                        ),
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _showCustomCategoryInput = false;
                              _customCategoryController.clear();
                            });
                          },
                          icon: Icon(Icons.cancel, color: AppTheme.errorRed),
                        ),
                      ],
                    ),
                    // Suggestions from what the marketplace actually contains,
                    // so the user picks a spelling that can match instead of
                    // guessing one that cannot.
                    Builder(builder: (context) {
                      final suggestions = Category.suggestFilterNames(
                        _customCategoryController.text,
                        _vocabulary,
                      );
                      if (suggestions.isEmpty) return const SizedBox(height: 4);
                      return Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final name in suggestions)
                              ActionChip(
                                label: Text(name, style: const TextStyle(fontSize: 13)),
                                onPressed: () => _addCustomCategory(name),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                  side: BorderSide(
                                    color: isDark
                                        ? AppTheme.darkBorder
                                        : AppTheme.lightBorder,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                  const SizedBox(height: 24),

                  // Location — one searchable field over the national dataset,
                  // replacing a 17-item city dropdown chained to an area chip
                  // row. Same picker as the posting flow, so what people search
                  // for when posting is what they search for when filtering.
                  Text(
                    'Location',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    button: true,
                    label: 'Filter location: $_locationLabel. Tap to change.',
                    child: InkWell(
                      onTap: _chooseLocation,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _selectedCity.isEmpty
                                ? (isDark ? AppTheme.darkBorder : AppTheme.lightBorder)
                                : AppTheme.primaryAccent.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Iconsax.location,
                              size: 20,
                              color: _selectedCity.isEmpty
                                  ? (isDark
                                      ? AppTheme.darkTextTertiary
                                      : AppTheme.lightTextTertiary)
                                  : AppTheme.primaryAccent,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _locationLabel,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: _selectedCity.isEmpty
                                      ? (isDark
                                          ? AppTheme.darkTextTertiary
                                          : AppTheme.lightTextTertiary)
                                      : (isDark
                                          ? AppTheme.darkTextPrimary
                                          : AppTheme.lightTextPrimary),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 20,
                              color: isDark
                                  ? AppTheme.darkTextTertiary
                                  : AppTheme.lightTextTertiary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Price ─────────────────────────────────────────────────
                  //
                  // Bands, not a slider. The old control spanned 0–100,000 KES
                  // in 20 divisions, so its smallest step was 5,000 — and the
                  // entire production corpus (median 600, maximum 4,500) fits
                  // inside that first step. Moving the minimum handle one notch
                  // emptied Discover; moving the maximum did nothing until it
                  // fell below 5,000. See [PriceBand].
                  Text(
                    'Price',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final band in PriceBand.all)
                        FilterChip(
                          selected: band.matches(_selection),
                          showCheckmark: false,
                          label: Text(band.isAny ? band.label : 'KES ${band.label}'),
                          onSelected: (_) => setState(() {
                            _minPrice = band.min;
                            _maxPrice = band.max;
                          }),
                          selectedColor: AppTheme.primaryAccent.withValues(alpha: 0.2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Urgency
                  Text(
                    'Urgency',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: Urgency.values.map((urgency) {
                      final isSelected = _selectedUrgency == urgency;
                      String label;
                      Color color;
                      switch (urgency) {
                        case Urgency.urgent:
                          label = 'High';
                          color = AppTheme.errorRed;
                          break;
                        case Urgency.soon:
                          label = 'Medium';
                          color = AppTheme.warningOrange;
                          break;
                        case Urgency.flexible:
                          label = 'Low';
                          color = AppTheme.successGreen;
                          break;
                      }
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: urgency != Urgency.flexible ? 8 : 0,
                          ),
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedUrgency = isSelected ? null : urgency;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? color.withValues(alpha: 0.2)
                                    : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected
                                      ? color
                                      : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: color,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    label,
                                    style: TextStyle(
                                      color: isSelected
                                          ? color
                                          : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  // Complexity REMOVED. The posting flow stopped asking for it,
                  // so every row in production carries the same default value:
                  // 'Easy' and 'Hard' matched zero posts and emptied Discover,
                  // 'Any' was matched as a literal value, and 'Medium' was the
                  // whole corpus. A filter with no answerable options is worse
                  // than no filter. The column and the server parameter are
                  // untouched — the client simply stopped asking.
                  //
                  // Minimum Rating filter removed (Phase 3.2C cleanup): provider
                  // rating is backend-derived and per-provider, not a syncable
                  // post field — client-side rating filtering is not supported.
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
          // Bottom Buttons
          Container(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              bottom: MediaQuery.of(context).padding.bottom + 20,
              top: 12,
            ),
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
              border: Border(
                top: BorderSide(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    // Leaves with NO answer, so the caller does nothing at all.
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Iconsax.close_circle),
                    label: const Text('Exit'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, _selection),
                    icon: const Icon(Iconsax.search_normal),
                    label: const Text('Search'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
