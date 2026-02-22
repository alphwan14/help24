import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';

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
  late double? _minRating;
  
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
    _minRating = provider.minRating;
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final availableAreas = _selectedCity.isNotEmpty 
        ? KenyaLocation.getByCity(_selectedCity)
        : <KenyaLocation>[];

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
                      _minRating = null;
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

                  // Location - City
                  Text(
                    'Location',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                      ),
                    ),
                    child: DropdownButton<String>(
                      value: _selectedCity.isEmpty ? null : _selectedCity,
                      hint: const Text('Select City'),
                      isExpanded: true,
                      underline: const SizedBox(),
                      dropdownColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('All Cities'),
                        ),
                        ...KenyaLocation.cities.map((city) {
                          return DropdownMenuItem(
                            value: city,
                            child: Text(city),
                          );
                        }),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedCity = value ?? '';
                          _selectedArea = '';
                        });
                      },
                    ),
                  ),
                  // Area selection
                  if (_selectedCity.isNotEmpty && availableAreas.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Area',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: availableAreas.map((location) {
                        final isSelected = _selectedArea == location.area;
                        return ChoiceChip(
                          label: Text(location.area),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              _selectedArea = selected ? location.area : '';
                            });
                          },
                          selectedColor: AppTheme.primaryAccent.withValues(alpha: 0.2),
                        );
                      }).toList(),
                    ),
                  ],
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
                        'Kes.${formatPriceFull(_priceRange.start)} - Kes.${formatPriceFull(_priceRange.end)}',
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
                  const SizedBox(height: 24),

                  // Rating
                  Text(
                    'Minimum Rating',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [1, 2, 3, 4, 5].map((rating) {
                      final isSelected = _minRating != null && rating <= _minRating!;
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _minRating = _minRating == rating.toDouble() ? null : rating.toDouble();
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            isSelected ? Icons.star_rounded : Icons.star_outline_rounded,
                            color: isSelected ? AppTheme.warningOrange : (isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary),
                            size: 32,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 32),
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
                      provider.setMinRating(_minRating);
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
