import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/place.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/location_provider.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import 'location_picker.dart';

class FilterBottomSheet extends StatefulWidget {
  const FilterBottomSheet({super.key});

  @override
  State<FilterBottomSheet> createState() => _FilterBottomSheetState();
}

class _FilterBottomSheetState extends State<FilterBottomSheet> {
  late Set<String> _selectedCategories;
  late String _selectedCity;
  late String _selectedArea;
  late RangeValues _priceRange;
  late Difficulty? _selectedDifficulty;
  late Urgency? _selectedUrgency;

  final _customCategoryController = TextEditingController();
  bool _showCustomCategoryInput = false;

  @override
  void initState() {
    super.initState();
    final provider = context.read<AppProvider>();
    _selectedCategories = Set.from(provider.selectedCategories);
    _selectedCity = provider.selectedCity;
    _selectedArea = provider.selectedArea;
    _priceRange = provider.priceRange;
    _selectedDifficulty = provider.selectedDifficulty;
    _selectedUrgency = provider.selectedUrgency;
  }

  @override
  void dispose() {
    _customCategoryController.dispose();
    super.dispose();
  }

  void _addCustomCategory() {
    final name = _customCategoryController.text.trim();
    if (name.isNotEmpty && !_selectedCategories.contains(name)) {
      setState(() {
        _selectedCategories.add(name);
        _customCategoryController.clear();
        _showCustomCategoryInput = false;
      });
    }
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
                  onPressed: () {
                    setState(() {
                      _selectedCategories = {};
                      _selectedCity = '';
                      _selectedArea = '';
                      _priceRange = const RangeValues(0, 100000);
                      _selectedDifficulty = null;
                      _selectedUrgency = null;
                    });
                  },
                  child: Text(
                    'Clear All',
                    style: TextStyle(color: AppTheme.primaryAccent),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Categories
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
                        final isSelected = _selectedCategories.contains(category.name);
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
                              if (selected) {
                                _selectedCategories.add(category.name);
                              } else {
                                _selectedCategories.remove(category.name);
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
                            decoration: InputDecoration(
                              hintText: 'Enter your profession...',
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            ),
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

                  // Price Range
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Price Range',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(
                        '${formatPriceDisplay(_priceRange.start)} - ${formatPriceDisplay(_priceRange.end)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.primaryAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  RangeSlider(
                    values: _priceRange,
                    min: 0,
                    max: 100000,
                    divisions: 20,
                    onChanged: (values) {
                      setState(() {
                        _priceRange = values;
                      });
                    },
                  ),
                  const SizedBox(height: 24),

                  // Complexity/Difficulty
                  Text(
                    'Complexity',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: Difficulty.values.map((difficulty) {
                      final isSelected = _selectedDifficulty == difficulty;
                      String label = difficulty.name[0].toUpperCase() + difficulty.name.substring(1);
                      Color color;
                      switch (difficulty) {
                        case Difficulty.easy:
                          color = AppTheme.successGreen;
                          break;
                        case Difficulty.medium:
                          color = AppTheme.warningOrange;
                          break;
                        case Difficulty.hard:
                          color = AppTheme.errorRed;
                          break;
                        case Difficulty.any:
                          color = isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary;
                          break;
                      }
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: difficulty != Difficulty.any ? 8 : 0,
                          ),
                          child: GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedDifficulty = isSelected ? null : difficulty;
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
                              child: Center(
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    color: isSelected
                                        ? color
                                        : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
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
                  // Minimum Rating filter removed (Phase 3.2C cleanup): provider
                  // rating is backend-derived and per-provider, not a syncable
                  // post field — client-side rating filtering is not supported.
                  const SizedBox(height: 24),
                ],
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
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Iconsax.close_circle),
                    label: const Text('Exit'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final provider = context.read<AppProvider>();
                      provider.clearFilters();
                      for (var category in _selectedCategories) {
                        provider.toggleCategory(category);
                      }
                      provider.setCity(_selectedCity);
                      if (_selectedArea.isNotEmpty) {
                        provider.setArea(_selectedArea);
                      }
                      provider.setPriceRange(_priceRange);
                      provider.setDifficulty(_selectedDifficulty);
                      provider.setUrgency(_selectedUrgency);
                      Navigator.pop(context);
                    },
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
