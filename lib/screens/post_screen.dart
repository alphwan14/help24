import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';
import '../models/post_model.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';

/// Represents a selected image with cross-platform support
class SelectedImage {
  final XFile file;
  final Uint8List? bytes; // For web preview
  final String name;

  SelectedImage({required this.file, this.bytes, required this.name});
}

class PostScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const PostScreen({super.key, required this.onComplete});

  @override
  State<PostScreen> createState() => _PostScreenState();
}

class _PostScreenState extends State<PostScreen> {
  int _currentStep = 0;
  PostType? _selectedType;
  
  // Form controllers
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _locationController = TextEditingController();
  final _customCategoryController = TextEditingController();
  
  Category? _selectedCategory;
  Urgency _selectedUrgency = Urgency.flexible;
  String _selectedCity = '';
  String _selectedArea = '';
  List<SelectedImage> _selectedImages = [];
  final ImagePicker _picker = ImagePicker();

  // Submission state
  bool _isSubmitting = false;
  int _uploadedImages = 0;
  int _totalImages = 0;

  @override
  void initState() {
    super.initState();
    // Add listeners to trigger rebuild when text changes (for button state)
    _titleController.addListener(_onFormChanged);
    _descriptionController.addListener(_onFormChanged);
    _priceController.addListener(_onFormChanged);
  }

  void _onFormChanged() {
    // Trigger rebuild to update button enabled state
    setState(() {});
  }

  @override
  void dispose() {
    _titleController.removeListener(_onFormChanged);
    _descriptionController.removeListener(_onFormChanged);
    _priceController.removeListener(_onFormChanged);
    _titleController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _locationController.dispose();
    _customCategoryController.dispose();
    super.dispose();
  }

  Future<void> _pickImages() async {
    try {
      final List<XFile> images = await _picker.pickMultiImage(
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );
      
      if (images.isNotEmpty) {
        final newImages = <SelectedImage>[];
        for (final img in images) {
          // Read bytes for web preview
          final bytes = await img.readAsBytes();
          
          // Validate file size (max 5MB)
          if (bytes.length > 5 * 1024 * 1024) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${img.name} is too large (max 5MB)'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
            continue;
          }
          
          // Trust image_picker to return valid images
          // Extension detection happens in StorageService during upload
          
          newImages.add(SelectedImage(
            file: img,
            bytes: bytes,
            name: img.name,
          ));
        }
        
        if (newImages.isNotEmpty) {
          setState(() {
            _selectedImages = [..._selectedImages, ...newImages].take(5).toList();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking images: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _takePhoto() async {
    // Camera not available on web
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Camera not available on web. Please use gallery.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );
      
      if (image != null && _selectedImages.length < 5) {
        final bytes = await image.readAsBytes();
        
        // Validate file size
        if (bytes.length > 5 * 1024 * 1024) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Image is too large (max 5MB)'),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
          return;
        }
        
        setState(() {
          _selectedImages.add(SelectedImage(
            file: image,
            bytes: bytes,
            name: image.name,
          ));
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error taking photo: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _removeImage(int index) {
    setState(() {
      _selectedImages.removeAt(index);
    });
  }

  void _showImageSourceDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // On web, skip dialog and go directly to gallery
    if (kIsWeb) {
      _pickImages();
      return;
    }
    
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Add Images',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _ImageSourceOption(
                  icon: Iconsax.camera,
                  label: 'Camera',
                  onTap: () {
                    Navigator.pop(context);
                    _takePhoto();
                  },
                ),
                _ImageSourceOption(
                  icon: Iconsax.gallery,
                  label: 'Gallery',
                  onTap: () {
                    Navigator.pop(context);
                    _pickImages();
                  },
                ),
              ],
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
          ],
        ),
      ),
    );
  }

  /// Build cross-platform image preview widget
  Widget _buildImagePreview(SelectedImage image, {BoxFit fit = BoxFit.cover}) {
    // Use bytes for preview (works on all platforms including web)
    if (image.bytes != null) {
      return Image.memory(
        image.bytes!,
        fit: fit,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: Colors.grey[300],
            child: const Icon(Icons.broken_image, color: Colors.grey),
          );
        },
      );
    }
    
    // Fallback placeholder
    return Container(
      color: Colors.grey[300],
      child: const Icon(Icons.image, color: Colors.grey),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                if (_currentStep > 0)
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _currentStep--;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                        ),
                      ),
                      child: Icon(
                        Icons.arrow_back,
                        color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                        size: 20,
                      ),
                    ),
                  ),
                if (_currentStep > 0) const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _getStepTitle(),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                GestureDetector(
                  onTap: widget.onComplete,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                      ),
                    ),
                    child: Icon(
                      Icons.close,
                      color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Progress Indicator
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: List.generate(3, (index) {
                return Expanded(
                  child: Container(
                    height: 4,
                    margin: EdgeInsets.only(right: index < 2 ? 8 : 0),
                    decoration: BoxDecoration(
                      color: index <= _currentStep
                          ? AppTheme.primaryAccent
                          : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                );
              }),
            ),
          ),

          const SizedBox(height: 24),

          // Content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _buildStepContent(),
            ),
          ),
        ],
      ),
    );
  }

  String _getStepTitle() {
    switch (_currentStep) {
      case 0:
        return 'What do you want to post?';
      case 1:
        return 'Add Details';
      case 2:
        return 'Preview & Post';
      default:
        return '';
    }
  }

  Widget _buildStepContent() {
    switch (_currentStep) {
      case 0:
        return _buildTypeSelection();
      case 1:
        return _buildFormStep();
      case 2:
        return _buildPreviewStep();
      default:
        return const SizedBox();
    }
  }

  Widget _buildTypeSelection() {
    return Column(
      children: [
        _TypeCard(
          icon: Iconsax.document_text,
          title: 'Post a Request',
          description: 'Looking for someone to help you with a task',
          isSelected: _selectedType == PostType.request,
          onTap: () {
            setState(() {
              _selectedType = PostType.request;
            });
          },
        ),
        const SizedBox(height: 12),
        _TypeCard(
          icon: Iconsax.lamp_charge,
          title: 'Post an Offer',
          description: 'Offer your services to potential clients',
          isSelected: _selectedType == PostType.offer,
          onTap: () {
            setState(() {
              _selectedType = PostType.offer;
            });
          },
        ),
        const SizedBox(height: 12),
        _TypeCard(
          icon: Iconsax.briefcase,
          title: 'Post a Job',
          description: 'Hire someone for a position or project',
          isSelected: _selectedType == PostType.job,
          onTap: () {
            setState(() {
              _selectedType = PostType.job;
            });
          },
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _selectedType != null
                ? () {
                    setState(() {
                      _currentStep = 1;
                    });
                  }
                : null,
            child: const Text('Continue'),
          ),
        ),
      ],
    );
  }

  Widget _buildFormStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final availableAreas = _selectedCity.isNotEmpty 
        ? KenyaLocation.getByCity(_selectedCity)
        : <KenyaLocation>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title
        Text('Title', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _titleController,
          decoration: const InputDecoration(
            hintText: 'What are you looking for?',
          ),
        ),
        const SizedBox(height: 20),

        // Description
        Text('Description', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _descriptionController,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Describe in detail...',
          ),
        ),
        const SizedBox(height: 20),

        // Category
        Text('Category', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: DropdownButton<Category>(
            value: _selectedCategory,
            hint: const Text('Select a category'),
            isExpanded: true,
            underline: const SizedBox(),
            dropdownColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            items: Category.all.map((category) {
              return DropdownMenuItem(
                value: category,
                child: Row(
                  children: [
                    Icon(category.icon, size: 20),
                    const SizedBox(width: 12),
                    Text(category.name),
                  ],
                ),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _selectedCategory = value;
              });
            },
          ),
        ),
        const SizedBox(height: 20),

        // Urgency
        Text('Urgency', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: Urgency.values.map((urgency) {
            final isSelected = _selectedUrgency == urgency;
            String label;
            Color color;
            switch (urgency) {
              case Urgency.urgent:
                label = 'Urgent';
                color = AppTheme.errorRed;
                break;
              case Urgency.soon:
                label = 'Soon';
                color = AppTheme.warningOrange;
                break;
              case Urgency.flexible:
                label = 'Flexible';
                color = AppTheme.successGreen;
                break;
            }
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: urgency != Urgency.flexible ? 8 : 0),
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedUrgency = urgency;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
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
        const SizedBox(height: 20),

        // Location - City
        Text('Location', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
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
            items: KenyaLocation.cities.map((city) {
              return DropdownMenuItem(
                value: city,
                child: Text(city),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _selectedCity = value ?? '';
                _selectedArea = '';
              });
            },
          ),
        ),
        if (_selectedCity.isNotEmpty && availableAreas.isNotEmpty) ...[
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
              value: _selectedArea.isEmpty ? null : _selectedArea,
              hint: const Text('Select Area'),
              isExpanded: true,
              underline: const SizedBox(),
              dropdownColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
              items: availableAreas.map((location) {
                return DropdownMenuItem(
                  value: location.area,
                  child: Text(location.area),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedArea = value ?? '';
                });
              },
            ),
          ),
        ],
        const SizedBox(height: 20),

        // Price
        Text('Price/Budget (KES)', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          controller: _priceController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '0',
            prefixIcon: Icon(Iconsax.money),
            prefixText: 'KES ',
          ),
        ),
        const SizedBox(height: 20),

        // Images (Optional)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text('Images', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  '(Optional)',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
                  ),
                ),
              ],
            ),
            Text(
              '${_selectedImages.length}/5',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 100,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              // Add image button
              if (_selectedImages.length < 5)
                GestureDetector(
                  onTap: _showImageSourceDialog,
                  child: Container(
                    width: 100,
                    height: 100,
                    margin: const EdgeInsets.only(right: 12),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: AppTheme.primaryAccent,
                        width: 2,
                        style: BorderStyle.solid,
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Iconsax.gallery_add,
                          color: AppTheme.primaryAccent,
                          size: 28,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          kIsWeb ? 'Browse' : 'Add',
                          style: TextStyle(
                            color: AppTheme.primaryAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Selected images with cross-platform preview
              ..._selectedImages.asMap().entries.map((entry) {
                return Stack(
                  children: [
                    Container(
                      width: 100,
                      height: 100,
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _buildImagePreview(entry.value),
                    ),
                    Positioned(
                      top: 4,
                      right: 16,
                      child: GestureDetector(
                        onTap: () => _removeImage(entry.key),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: AppTheme.errorRed,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 14,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 32),

        // Show what's missing if button is disabled
        if (!_canProceed()) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warningOrange.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.warningOrange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: AppTheme.warningOrange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _getMissingFieldsText(),
                    style: TextStyle(color: AppTheme.warningOrange, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _canProceed()
                ? () {
                    setState(() {
                      _currentStep = 2;
                    });
                  }
                : null,
            child: const Text('Preview'),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  String _getMissingFieldsText() {
    final missing = <String>[];
    if (_titleController.text.trim().isEmpty) missing.add('Title');
    if (_descriptionController.text.trim().isEmpty) missing.add('Description');
    if (_selectedCategory == null) missing.add('Category');
    if (_selectedCity.isEmpty) missing.add('Location');
    if (_priceController.text.trim().isEmpty) missing.add('Price');
    return 'Please fill in: ${missing.join(', ')}';
  }

  bool _canProceed() {
    // Images are NOT required - user can post without images
    final hasTitle = _titleController.text.trim().isNotEmpty;
    final hasDescription = _descriptionController.text.trim().isNotEmpty;
    final hasCategory = _selectedCategory != null;
    final hasCity = _selectedCity.isNotEmpty;
    final hasPrice = _priceController.text.trim().isNotEmpty;
    
    return hasTitle && hasDescription && hasCategory && hasCity && hasPrice;
  }

  Widget _buildPreviewStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final price = double.tryParse(_priceController.text) ?? 0;
    final location = _selectedArea.isNotEmpty 
        ? '$_selectedArea, $_selectedCity'
        : _selectedCity;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Preview your post',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),

        // Preview Card
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Images preview (only if images exist)
              if (_selectedImages.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: SizedBox(
                    height: 160,
                    width: double.infinity,
                    child: _selectedImages.length == 1
                        ? _buildImagePreview(_selectedImages[0])
                        : Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: SizedBox(
                                  height: double.infinity,
                                  child: _buildImagePreview(_selectedImages[0]),
                                ),
                              ),
                              const SizedBox(width: 2),
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: SizedBox(
                                        width: double.infinity,
                                        child: _buildImagePreview(_selectedImages[1]),
                                      ),
                                    ),
                                    if (_selectedImages.length > 2) ...[
                                      const SizedBox(height: 2),
                                      Expanded(
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            _buildImagePreview(_selectedImages[2]),
                                            if (_selectedImages.length > 3)
                                              Container(
                                                color: Colors.black54,
                                                child: Center(
                                                  child: Text(
                                                    '+${_selectedImages.length - 3}',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 18,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            _selectedCategory?.icon ?? Icons.category,
                            color: AppTheme.primaryAccent,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _titleController.text,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _descriptionController.text,
                                style: Theme.of(context).textTheme.bodyMedium,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _PreviewChip(
                          icon: Icons.location_on_outlined,
                          text: location,
                        ),
                        const SizedBox(width: 8),
                        _PreviewChip(
                          icon: Icons.attach_money,
                          text: 'Kes.${formatPriceFull(price)}',
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: _getUrgencyColor().withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: _getUrgencyColor(),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _getUrgencyText(),
                                style: TextStyle(
                                  color: _getUrgencyColor(),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 32),

        // Upload progress indicator (only when uploading images)
        if (_isSubmitting && _totalImages > 0) ...[
          Column(
            children: [
              Text(
                'Uploading images ($_uploadedImages/$_totalImages)',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _totalImages > 0 ? _uploadedImages / _totalImages : null,
                backgroundColor: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryAccent),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ],

        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: _isSubmitting ? null : _submitPost,
            child: _isSubmitting
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(_selectedImages.isEmpty ? 'Posting...' : 'Uploading...'),
                    ],
                  )
                : const Text('Post Now'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton(
            onPressed: _isSubmitting ? null : () {
              setState(() {
                _currentStep = 1;
              });
            },
            child: const Text('Edit'),
          ),
        ),
      ],
    );
  }

  Color _getUrgencyColor() {
    switch (_selectedUrgency) {
      case Urgency.urgent:
        return AppTheme.errorRed;
      case Urgency.soon:
        return AppTheme.warningOrange;
      case Urgency.flexible:
        return AppTheme.successGreen;
    }
  }

  String _getUrgencyText() {
    switch (_selectedUrgency) {
      case Urgency.urgent:
        return 'Urgent';
      case Urgency.soon:
        return 'Soon';
      case Urgency.flexible:
        return 'Flexible';
    }
  }

  Future<void> _submitPost() async {
    if (_isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _uploadedImages = 0;
      _totalImages = _selectedImages.length;
    });

    final provider = context.read<AppProvider>();
    final price = double.tryParse(_priceController.text) ?? 0;
    final location = _selectedArea.isNotEmpty 
        ? '$_selectedArea, $_selectedCity'
        : _selectedCity;

    try {
      await AuthService.ensureCurrentUserInSupabase();
      if (_selectedType == PostType.job) {
        final job = JobModel(
          id: '',
          title: _titleController.text,
          company: '',
          location: location,
          pay: 'Kes.${formatPriceFull(price)}',
          description: _descriptionController.text,
        );

        final currentUserId = context.read<AuthProvider>().currentUserId;
        final createdJob = await provider.createJob(
          job,
          currentUserId: currentUserId,
          imageFiles: _selectedImages.map((img) => img.file).toList(),
          onImageUploadProgress: (completed, total) {
            if (mounted) {
              setState(() {
                _uploadedImages = completed;
                _totalImages = total;
              });
            }
          },
        );

        if (createdJob == null) {
          throw Exception(provider.error ?? 'Failed to create job');
        }
      } else {
        final post = PostModel(
          id: '',
          title: _titleController.text,
          description: _descriptionController.text,
          category: _selectedCategory ?? Category.all.last,
          location: location,
          price: price,
          urgency: _selectedUrgency,
          type: _selectedType ?? PostType.request,
        );

        final currentUserId = context.read<AuthProvider>().currentUserId;
        final createdPost = await provider.createPost(
          post,
          currentUserId: currentUserId,
          imageFiles: _selectedImages.map((img) => img.file).toList(),
          onImageUploadProgress: (completed, total) {
            if (mounted) {
              setState(() {
                _uploadedImages = completed;
                _totalImages = total;
              });
            }
          },
        );

        if (createdPost == null) {
          throw Exception(provider.error ?? 'Failed to create post');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('Posted successfully!'),
              ],
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppTheme.successGreen,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );

        widget.onComplete();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(child: Text('Error: $e')),
              ],
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppTheme.errorRed,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            action: SnackBarAction(
              label: 'Retry',
              textColor: Colors.white,
              onPressed: _submitPost,
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }
}

class _TypeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool isSelected;
  final VoidCallback onTap;

  const _TypeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryAccent.withValues(alpha: 0.1)
              : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? AppTheme.primaryAccent
                : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.primaryAccent.withValues(alpha: 0.2)
                    : (isDark ? AppTheme.darkSurface : AppTheme.lightBackground),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                icon,
                color: isSelected
                    ? AppTheme.primaryAccent
                    : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: isSelected ? AppTheme.primaryAccent : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (isSelected)
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: AppTheme.primaryAccent,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.check,
                  color: Colors.white,
                  size: 16,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PreviewChip extends StatelessWidget {
  final IconData icon;
  final String text;

  const _PreviewChip({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : AppTheme.lightBackground,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageSourceOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ImageSourceOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppTheme.primaryAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              color: AppTheme.primaryAccent,
              size: 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}
