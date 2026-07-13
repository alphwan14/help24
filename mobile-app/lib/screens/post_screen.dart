import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';
import '../models/category_schema.dart';
import '../models/job_flow.dart';
import '../models/offer_flow.dart';
import '../models/post_model.dart';
import '../models/request_flow.dart';
import '../providers/app_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../services/auth_service.dart';
import '../services/category_schema_service.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';
import '../utils/format_utils.dart';
import '../widgets/schema_question_flow.dart';

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
  PricingType _selectedPricingType = PricingType.task;
  EmploymentType? _selectedEmploymentType;
  String _selectedCity = '';
  String _selectedArea = '';
  List<SelectedImage> _selectedImages = [];
  final ImagePicker _picker = ImagePicker();

  // Submission state
  bool _isSubmitting = false;
  int _uploadedImages = 0;
  int _totalImages = 0;

  // Smart Posting: category question answers + whether the current run of the
  // wizard includes the guided-questions step. The flag is SNAPSHOTTED when
  // leaving the form step so a late schema fetch can never reshuffle steps
  // mid-flow.
  Map<String, dynamic> _attributes = {};

  // Posting Redesign R-1: request-journey state. Offers and jobs still use the
  // legacy form until R-2/R-3.
  RequestWhen? _when;
  bool? _budgetOpen; // null = not chosen, true = open to offers, false = amount
  bool _includeQuestions = false; // request-path snapshot (set on the When step)
  int _reqAdvanceToken = 0;
  final _categorySearchController = TextEditingController();

  bool get _isRequestFlow => _selectedType == PostType.request;

  List<RequestStepId> get _reqSteps => requestSteps(includeQuestions: _includeQuestions);

  RequestStepId? get _currentReqStep =>
      (_isRequestFlow && _currentStep > 0 && _currentStep <= _reqSteps.length)
          ? _reqSteps[_currentStep - 1]
          : null;

  // Posting Redesign R-2: offer-journey state.
  OfferAvailability? _availability;

  bool get _isOfferFlow => _selectedType == PostType.offer;

  List<OfferStepId> get _offerSteps => offerSteps(includeQuestions: _includeQuestions);

  OfferStepId? get _currentOfferStep =>
      (_isOfferFlow && _currentStep > 0 && _currentStep <= _offerSteps.length)
          ? _offerSteps[_currentStep - 1]
          : null;

  // Posting Redesign R-3: job-journey state.
  JobStart? _start;

  bool get _isJobFlow => _selectedType == PostType.job;

  List<JobStepId> get _jobSteps => jobSteps(includeQuestions: _includeQuestions);

  JobStepId? get _currentJobStep =>
      (_isJobFlow && _currentStep > 0 && _currentStep <= _jobSteps.length)
          ? _jobSteps[_currentStep - 1]
          : null;

  /// Price actually submitted/previewed. Requests honor Budget semantics
  /// ("Open to offers" → 0); offers/jobs read the plain field as before.
  double get _effectivePrice => _isRequestFlow
      ? requestPrice(openToOffers: _budgetOpen != false, budgetText: _priceController.text)
      : (double.tryParse(_priceController.text) ?? 0);

  /// Switch intent — per-intent state must never leak across intents (e.g. a
  /// request's "Right now" urgency leaking into an offer post).
  void _selectType(PostType type) {
    setState(() {
      if (type != _selectedType) {
        _when = null;
        _budgetOpen = null;
        _availability = null;
        _start = null;
        _includeQuestions = false;
        _selectedUrgency = Urgency.flexible;
        _attributes = {};
        // Sensible money default per intent: salary is monthly, services per task.
        _selectedPricingType =
            type == PostType.job ? PricingType.month : PricingType.task;
      }
      _selectedType = type;
    });
  }

  @override
  void initState() {
    super.initState();
    // Add listeners to trigger rebuild when text changes (for button state)
    _titleController.addListener(_onFormChanged);
    _descriptionController.addListener(_onFormChanged);
    _priceController.addListener(_onFormChanged);
    // Warm the category registry (cache-first, fire-and-forget — never blocks).
    CategorySchemaService.instance.warmUp();
    // Pre-fill city from cached location (non-blocking, never prevents posting).
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefillLocationFromCache());
  }

  bool get _isEmergency => _selectedUrgency == Urgency.urgent;

  String get _postTypeName => (_selectedType ?? PostType.request).name;

  /// The schema for the chosen category, or null when the generic form is all
  /// we need (no schema, or every step filtered out for this type/urgency).
  QuestionSchema? get _activeSchema {
    final cat = _selectedCategory;
    if (cat == null) return null;
    final schema = CategorySchemaService.instance.schemaFor(cat.name);
    if (schema == null) return null;
    final visible = schema.visibleSteps(
      answers: _attributes,
      postType: _postTypeName,
      emergency: _isEmergency,
    );
    return visible.isEmpty ? null : schema;
  }

  int get _totalSteps => _isRequestFlow
      ? 1 + _reqSteps.length
      : _isOfferFlow
          ? 1 + _offerSteps.length
          : _isJobFlow
              ? 1 + _jobSteps.length
              : 3; // pre-selection placeholder (step 0 only)

  /// Answers actually submitted: pruned so hidden conditionals (changed parent
  /// answer, emergency mode) never leak into the post.
  Map<String, dynamic> get _submittableAttributes {
    final cat = _selectedCategory;
    if (cat == null || _attributes.isEmpty) return const {};
    final schema = CategorySchemaService.instance.schemaFor(cat.name);
    if (schema == null) return const {};
    return schema.prunedAnswers(
      answers: _attributes,
      postType: _postTypeName,
      emergency: _isEmergency,
    );
  }

  void _prefillLocationFromCache() {
    if (!mounted) return;
    final cachedCity = context.read<LocationProvider>().city;
    if (cachedCity == null || cachedCity.isEmpty || _selectedCity.isNotEmpty) return;
    // Only autofill when the cached city is in the predefined list.
    final cities = KenyaLocation.cities;
    final match = cities.firstWhere(
      (c) => c.toLowerCase() == cachedCity.toLowerCase(),
      orElse: () => '',
    );
    if (match.isNotEmpty) {
      setState(() => _selectedCity = match);
    }
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
    _categorySearchController.dispose();
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
      top: false,
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
              children: List.generate(_totalSteps, (index) {
                return Expanded(
                  child: Container(
                    height: 4,
                    margin: EdgeInsets.only(right: index < _totalSteps - 1 ? 8 : 0),
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

          // Content — one light fade/slide between steps (matches the schema flow).
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero)
                        .animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey('step_$_currentStep'),
                  child: _buildStepContent(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getStepTitle() {
    if (_currentStep == 0) return 'What would you like to do?';
    if (_isRequestFlow) {
      switch (_currentReqStep) {
        case RequestStepId.category:
          return 'What do you need?';
        case RequestStepId.title:
          return 'Give it a title';
        case RequestStepId.when:
          return 'When do you need it?';
        case RequestStepId.questions:
          return _selectedCategory?.name ?? 'Quick questions';
        case RequestStepId.budget:
          return 'Your budget';
        case RequestStepId.location:
          return 'Where?';
        case RequestStepId.photos:
          return 'Add photos';
        case RequestStepId.details:
          return 'Anything else?';
        default:
          return 'Preview & Post';
      }
    }
    if (_isOfferFlow) {
      switch (_currentOfferStep) {
        case OfferStepId.category:
          return 'What do you offer?';
        case OfferStepId.title:
          return 'Give it a title';
        case OfferStepId.questions:
          return _selectedCategory?.name ?? 'Quick questions';
        case OfferStepId.price:
          return 'Your starting price';
        case OfferStepId.availability:
          return 'When are you available?';
        case OfferStepId.location:
          return 'Where do you work?';
        case OfferStepId.photos:
          return 'Show your work';
        case OfferStepId.description:
          return 'Describe your service';
        default:
          return 'Preview & Post';
      }
    }
    if (_isJobFlow) {
      switch (_currentJobStep) {
        case JobStepId.category:
          return 'Who are you hiring?';
        case JobStepId.title:
          return 'Job title';
        case JobStepId.employment:
          return 'What kind of job?';
        case JobStepId.salary:
          return 'Salary / Pay';
        case JobStepId.start:
          return 'When do they start?';
        case JobStepId.questions:
          return _selectedCategory?.name ?? 'Quick questions';
        case JobStepId.description:
          return 'Describe the role';
        case JobStepId.location:
          return 'Where is the job?';
        default:
          return 'Preview & Post';
      }
    }
    return 'Preview & Post';
  }

  Widget _buildStepContent() {
    if (_currentStep == 0) return _buildTypeSelection();
    if (_isRequestFlow) {
      switch (_currentReqStep) {
        case RequestStepId.category:
          return _buildCategoryStep();
        case RequestStepId.title:
          return _buildTitleStep();
        case RequestStepId.when:
          return _buildWhenStep();
        case RequestStepId.questions:
          return _buildQuestionsStep();
        case RequestStepId.budget:
          return _buildBudgetStep();
        case RequestStepId.location:
          return _buildRequestLocationStep();
        case RequestStepId.photos:
          return _buildPhotosStep();
        case RequestStepId.details:
          return _buildDetailsStep();
        case RequestStepId.preview:
          return _buildPreviewStep();
        default:
          return const SizedBox();
      }
    }
    if (_isOfferFlow) {
      switch (_currentOfferStep) {
        case OfferStepId.category:
          return _buildCategoryStep();
        case OfferStepId.title:
          return _buildTitleStep();
        case OfferStepId.questions:
          return _buildQuestionsStep();
        case OfferStepId.price:
          return _buildOfferPriceStep();
        case OfferStepId.availability:
          return _buildAvailabilityStep();
        case OfferStepId.location:
          return _buildRequestLocationStep();
        case OfferStepId.photos:
          return _buildPhotosStep();
        case OfferStepId.description:
          return _buildDetailsStep();
        case OfferStepId.preview:
          return _buildPreviewStep();
        default:
          return const SizedBox();
      }
    }
    if (_isJobFlow) {
      switch (_currentJobStep) {
        case JobStepId.category:
          return _buildCategoryStep();
        case JobStepId.title:
          return _buildTitleStep();
        case JobStepId.employment:
          return _buildEmploymentStep();
        case JobStepId.salary:
          return _buildSalaryStep();
        case JobStepId.start:
          return _buildStartStep();
        case JobStepId.questions:
          return _buildQuestionsStep();
        case JobStepId.description:
          return _buildDetailsStep();
        case JobStepId.location:
          return _buildRequestLocationStep();
        case JobStepId.preview:
          return _buildPreviewStep();
        default:
          return const SizedBox();
      }
    }
    return const SizedBox();
  }

  /// Smart Posting: the guided category questions, rendered entirely from the
  /// server schema (no category-specific widgets anywhere). In BOTH paths the
  /// questions screen is immediately followed by its successor, so finishing
  /// (or a vanished schema) simply moves one step forward.
  Widget _buildQuestionsStep() {
    final schema = _activeSchema;
    final stepAtBuild = _currentStep;
    if (schema == null) {
      // Schema vanished (category changed underneath) — skip this screen.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _currentStep == stepAtBuild) {
          setState(() => _currentStep++);
        }
      });
      return const SizedBox.shrink();
    }
    return SchemaQuestionFlow(
      // Reset the flow whenever its inputs change identity.
      key: ValueKey('${_selectedCategory?.name}|$_postTypeName|$_isEmergency'),
      schema: schema,
      postType: _postTypeName,
      emergency: _isEmergency,
      initialAnswers: _attributes,
      onAnswersChanged: (a) => setState(() => _attributes = Map.of(a)),
      onFinished: () => setState(() => _currentStep++),
    );
  }

  Widget _buildTypeSelection() {
    return Column(
      children: [
        _TypeCard(
          icon: Iconsax.document_text,
          title: 'Request a Service',
          description: 'Looking for someone to help you with a task or service',
          isSelected: _selectedType == PostType.request,
          onTap: () => _selectType(PostType.request),
        ),
        const SizedBox(height: 12),
        _TypeCard(
          icon: Iconsax.lamp_charge,
          title: 'Offer a Service',
          description: 'Share your skills and get hired by people who need help',
          isSelected: _selectedType == PostType.offer,
          onTap: () => _selectType(PostType.offer),
        ),
        const SizedBox(height: 12),
        _TypeCard(
          icon: Iconsax.briefcase,
          title: 'Post a Job',
          description: 'Hire someone for a position or project',
          isSelected: _selectedType == PostType.job,
          onTap: () => _selectType(PostType.job),
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

  // ───────────────────────── shared field builders ──────────────────────────

  /// City (+ optional Area) dropdowns — the Location step of all three flows.
  List<Widget> _buildLocationFields(bool isDark) {
    final availableAreas = _selectedCity.isNotEmpty
        ? KenyaLocation.getByCity(_selectedCity)
        : <KenyaLocation>[];
    return [
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
    ];
  }

  /// Horizontal add/preview strip — the Photos step of the request and offer
  /// flows (the job journey deliberately has no photos).
  Widget _buildImagePickerStrip(bool isDark) {
    return SizedBox(
      height: 100,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
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
    );
  }

  // ─────────────────────── request journey (R-1) steps ──────────────────────

  /// Advance with a brief pause so the selection highlight registers
  /// (same rhythm as the schema question flow).
  void _advanceRequestDelayed() {
    final token = ++_reqAdvanceToken;
    Future.delayed(const Duration(milliseconds: 220), () {
      if (mounted && token == _reqAdvanceToken) {
        setState(() => _currentStep++);
      }
    });
  }

  Widget _flowContinueButton({
    required bool enabled,
    String label = 'Continue',
    VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: enabled ? (onPressed ?? () => setState(() => _currentStep++)) : null,
        child: Text(label),
      ),
    );
  }

  /// Category first — it routes everything else. Searchable tile list,
  /// one tap to select and advance.
  Widget _buildCategoryStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final query = _categorySearchController.text.trim().toLowerCase();
    final categories = CategorySchemaService.instance.categories
        .where((c) => query.isEmpty || c.name.toLowerCase().contains(query))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _categorySearchController,
          decoration: const InputDecoration(
            hintText: 'Search — fundi, cleaner, tutor…',
            prefixIcon: Icon(Iconsax.search_normal, size: 20),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        for (final category in categories) ...[
          ChoiceTile(
            label: category.name,
            icon: category.icon,
            selected: _selectedCategory?.name == category.name,
            isDark: isDark,
            onTap: () {
              setState(() {
                // Different category → its questions (and old answers) no longer apply.
                if (category.name != _selectedCategory?.name) _attributes = {};
                _selectedCategory = category;
              });
              _advanceRequestDelayed();
            },
          ),
          const SizedBox(height: 10),
        ],
        if (categories.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text(
              'Nothing matches — try another word.',
              style: TextStyle(
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ),
        const SizedBox(height: 20),
      ],
    );
  }

  /// Title stays manual and natural — English, Kiswahili or Sheng.
  Widget _buildTitleStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _titleController,
          autofocus: _titleController.text.isEmpty,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: _isOfferFlow
                ? 'e.g. "Fundi wa magari — engine na brakes"'
                : _isJobFlow
                    ? 'e.g. "Tunatafuta cleaner — Westlands office"'
                    : 'e.g. "Nahitaji fundi wa fridge"',
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Write it the way you\'d say it — English, Kiswahili or Sheng.',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
          ),
        ),
        const SizedBox(height: 28),
        _flowContinueButton(
          enabled: _titleController.text.trim().isNotEmpty,
          // Offers and jobs snapshot the questions step HERE (category + type
          // known; no emergency mode to wait for). Requests snapshot on the
          // When step instead.
          onPressed: (_isOfferFlow || _isJobFlow)
              ? () => setState(() {
                    _includeQuestions = _activeSchema != null;
                    _currentStep++;
                  })
              : null,
        ),
      ],
    );
  }

  /// Offer: starting price is REQUIRED — a seller must price their service.
  Widget _buildOfferPriceStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final amount = offerStartingPrice(_priceController.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _priceController,
          autofocus: _priceController.text.isEmpty,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '500',
            prefixIcon: Icon(Iconsax.money),
            prefixText: 'KES ',
          ),
        ),
        const SizedBox(height: 16),
        Text('How do you charge?', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in PricingType.values)
              _rateChip(
                label: p.displayLabel,
                selected: _selectedPricingType == p,
                isDark: isDark,
                onTap: () => setState(() => _selectedPricingType = p),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (amount != null)
          Text(
            'Clients see: From KES ${formatPriceFull(amount)} · ${_selectedPricingType.displayLabel}',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
          ),
        const SizedBox(height: 24),
        _flowContinueButton(enabled: amount != null),
      ],
    );
  }

  Widget _rateChip({
    required String label,
    required bool selected,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primaryAccent.withValues(alpha: 0.15)
              : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: selected
                ? AppTheme.primaryAccent
                : (isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected
                ? AppTheme.primaryAccent
                : (isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary),
          ),
        ),
      ),
    );
  }

  /// Offer: availability replaces urgency (an offer is never "urgent").
  Widget _buildAvailabilityStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        for (final a in OfferAvailability.values) ...[
          ChoiceTile(
            label: a.label,
            subtitle: a.subtitle,
            selected: _availability == a,
            isDark: isDark,
            onTap: () {
              setState(() => _availability = a);
              _advanceRequestDelayed();
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// "When do you need it?" replaces the abstract urgency chips. Right now =
  /// emergency mode (fewer questions, urgent badge + 1h urgent window).
  Widget _buildWhenStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        for (final when in RequestWhen.values) ...[
          ChoiceTile(
            label: when.label,
            subtitle: when.subtitle,
            icon: when == RequestWhen.rightNow ? Icons.bolt : null,
            selected: _when == when,
            isDark: isDark,
            onTap: () {
              setState(() {
                _when = when;
                _selectedUrgency = when.urgency; // legacy column stays truthful
                // Snapshot: does this run include the questions screen? Decided
                // here (category + emergency are now known) so a late schema
                // fetch can never reshuffle the steps mid-flow.
                _includeQuestions = _activeSchema != null;
              });
              _advanceRequestDelayed();
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// Budget with "Open to offers" as a first-class answer (price = 0).
  Widget _buildBudgetStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final amountOk =
        requestPrice(openToOffers: false, budgetText: _priceController.text) > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChoiceTile(
          label: 'Open to offers',
          subtitle: 'Providers tell you their price',
          selected: _budgetOpen == true,
          isDark: isDark,
          onTap: () {
            setState(() => _budgetOpen = true);
            _advanceRequestDelayed();
          },
        ),
        const SizedBox(height: 10),
        ChoiceTile(
          label: 'I have a budget',
          subtitle: 'Set what you\'re willing to pay',
          selected: _budgetOpen == false,
          isDark: isDark,
          onTap: () => setState(() => _budgetOpen = false),
        ),
        if (_budgetOpen == false) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _priceController,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              hintText: '0',
              prefixIcon: Icon(Iconsax.money),
              prefixText: 'KES ',
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            TextButton(
              onPressed: () {
                setState(() {
                  _budgetOpen = true;
                  _currentStep++;
                });
              },
              child: Text(
                'Skip',
                style: TextStyle(
                  color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
              ),
            ),
            const Spacer(),
            if (_budgetOpen == false)
              SizedBox(
                height: 46,
                child: ElevatedButton(
                  onPressed: amountOk ? () => setState(() => _currentStep++) : null,
                  child: const Text('Continue'),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildRequestLocationStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ..._buildLocationFields(isDark),
        const SizedBox(height: 10),
        if (_selectedCity.isNotEmpty)
          Text(
            _isOfferFlow
                ? 'Clients nearby find you first.'
                : 'Providers nearby see your request first.',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
          ),
        const SizedBox(height: 28),
        _flowContinueButton(enabled: _selectedCity.isNotEmpty),
      ],
    );
  }

  Widget _buildPhotosStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isOfferFlow
              ? 'Show your work — before/after photos win clients.'
              : 'A photo helps providers understand the problem before they arrive.',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
          ),
        ),
        const SizedBox(height: 12),
        _buildImagePickerStrip(isDark),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '${_selectedImages.length}/5',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 20),
        _flowContinueButton(
          enabled: true,
          label: _selectedImages.isEmpty ? 'Skip for now' : 'Continue',
        ),
      ],
    );
  }

  /// Free-text step. Requests: optional afterthought ("Anything else?").
  /// Offers: the pitch — optional but strongly encouraged.
  /// Jobs: the role definition — REQUIRED.
  Widget _buildDetailsStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final empty = _descriptionController.text.trim().isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _descriptionController,
          maxLines: _isRequestFlow ? 4 : 5,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: _isOfferFlow
                ? 'What you do, your experience, what makes you reliable…'
                : _isJobFlow
                    ? 'Duties, working hours, requirements, how to apply…'
                    : 'Anything providers should know — gate colour, best time to call…',
          ),
        ),
        const SizedBox(height: 10),
        Text(
          _isOfferFlow
              ? 'Optional — but offers with a description win more clients.'
              : _isJobFlow
                  ? 'Required — a clear role attracts serious applicants.'
                  : 'Optional — your answers already describe the job.',
          style: TextStyle(
            fontSize: 13,
            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
          ),
        ),
        const SizedBox(height: 28),
        _flowContinueButton(
          enabled: !_isJobFlow || !empty,
          label: (!_isJobFlow && empty) ? 'Skip for now' : 'Continue',
        ),
      ],
    );
  }

  /// Job: employment type as one-tap tiles (required; the DB trigger enforces
  /// it for type='job').
  Widget _buildEmploymentStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    String subtitleFor(EmploymentType e) {
      switch (e) {
        case EmploymentType.fullTime:
          return 'Permanent role, full days';
        case EmploymentType.partTime:
          return 'A few hours or days a week';
        case EmploymentType.contract:
          return 'Fixed period or project';
        case EmploymentType.temporary:
          return 'Short-term cover';
      }
    }

    return Column(
      children: [
        for (final e in EmploymentType.values) ...[
          ChoiceTile(
            label: e.displayLabel,
            subtitle: subtitleFor(e),
            selected: _selectedEmploymentType == e,
            isDark: isDark,
            onTap: () {
              setState(() => _selectedEmploymentType = e);
              _advanceRequestDelayed();
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  /// Job: salary is REQUIRED — pay transparency attracts serious applicants.
  Widget _buildSalaryStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final amount = jobSalary(_priceController.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _priceController,
          autofocus: _priceController.text.isEmpty,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: '25000',
            prefixIcon: Icon(Iconsax.money),
            prefixText: 'KES ',
          ),
        ),
        const SizedBox(height: 16),
        Text('How is it paid?', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in PricingType.values)
              _rateChip(
                label: p.displayLabel,
                selected: _selectedPricingType == p,
                isDark: isDark,
                onTap: () => setState(() => _selectedPricingType = p),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (amount != null)
          Text(
            'Applicants see: KES ${formatPriceFull(amount)} · ${_selectedPricingType.displayLabel}',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            ),
          ),
        const SizedBox(height: 24),
        _flowContinueButton(enabled: amount != null),
      ],
    );
  }

  /// Job: start date replaces urgency (recruitment has a start, not an
  /// emergency).
  Widget _buildStartStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        for (final s in JobStart.values) ...[
          ChoiceTile(
            label: s.label,
            subtitle: s.subtitle,
            selected: _start == s,
            isDark: isDark,
            onTap: () {
              setState(() => _start = s);
              _advanceRequestDelayed();
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildPreviewStep() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final price = _effectivePrice;
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
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: _getTypeBadgeColor().withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      _getTypeDisplayLabel(),
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: _getTypeBadgeColor(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (_selectedCategory != null)
                                    Text(
                                      _selectedCategory!.name,
                                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                        color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
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
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _PreviewChip(
                          icon: Icons.location_on_outlined,
                          text: location,
                        ),
                        _PreviewChip(
                          icon: Iconsax.money,
                          text: _isRequestFlow
                              ? (price <= 0
                                  ? 'Budget · Open to offers'
                                  : 'Budget · ${formatPriceDisplay(price)}')
                              : _isOfferFlow
                                  ? 'From ${formatPriceDisplay(price)} · ${_selectedPricingType.displayLabel}'
                                  : '${formatPriceDisplay(price)} · ${_selectedPricingType.displayLabel}',
                        ),
                        if (_isOfferFlow && _availability != null)
                          _PreviewChip(
                            icon: Iconsax.clock,
                            text: _availability!.label,
                          ),
                        if (_isJobFlow && _start != null)
                          _PreviewChip(
                            icon: Iconsax.calendar,
                            text: 'Starts: ${_start!.label}',
                          ),
                        if (_selectedType == PostType.job && _selectedEmploymentType != null)
                          _PreviewChip(
                            icon: Iconsax.briefcase,
                            text: _selectedEmploymentType!.displayLabel,
                          ),
                        // Urgency is a request concept — offers show
                        // availability, jobs show a start date.
                        if (_isRequestFlow)
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
                    // Smart Posting: collected answers, labeled from the schema.
                    if (_attributeSummary().isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in _attributeSummary())
                            _PreviewChip(icon: Iconsax.tick_circle, text: entry),
                        ],
                      ),
                    ],
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
                // Step back one screen; the header back button walks further.
                _currentStep = _currentStep - 1;
              });
            },
            child: const Text('Edit'),
          ),
        ),
      ],
    );
  }

  /// Human-readable summary of the collected answers for the preview card,
  /// resolved through the schema (option labels, Yes/No for booleans).
  List<String> _attributeSummary() {
    final cat = _selectedCategory;
    final answers = _submittableAttributes;
    if (cat == null || answers.isEmpty) return const [];
    final schema = CategorySchemaService.instance.schemaFor(cat.name);
    if (schema == null) return const [];
    final out = <String>[];
    for (final step in schema.steps) {
      final answer = answers[step.key];
      if (answer == null) continue;
      switch (step.type) {
        case 'select':
          for (final o in step.options) {
            if (o.value == answer.toString()) {
              out.add(o.label);
              break;
            }
          }
          break;
        case 'multiselect':
          final values = (answer as List).map((e) => e.toString()).toSet();
          out.addAll(step.options.where((o) => values.contains(o.value)).map((o) => o.label));
          break;
        case 'boolean':
          out.add('${step.question.replaceAll('?', '')} — ${answer == true ? 'Yes' : 'No'}');
          break;
        default:
          out.add(answer.toString());
      }
    }
    return out;
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

  Color _getTypeBadgeColor() {
    switch (_selectedType) {
      case PostType.request:
        return const Color(0xFF2196F3);
      case PostType.offer:
        return const Color(0xFF4CAF50);
      case PostType.job:
        return const Color(0xFF9C27B0);
      default:
        return AppTheme.primaryAccent;
    }
  }

  String _getTypeDisplayLabel() {
    switch (_selectedType) {
      case PostType.request:
        return 'Request';
      case PostType.offer:
        return 'Offer';
      case PostType.job:
        return 'Job';
      default:
        return 'Post';
    }
  }

  Future<void> _submitPost() async {
    if (_isSubmitting) return;

    setState(() {
      _isSubmitting = true;
      _uploadedImages = 0;
      // The job journey has no photos step — never upload images that were
      // picked during an earlier request/offer attempt in this session.
      _totalImages = _isJobFlow ? 0 : _selectedImages.length;
    });

    final provider = context.read<AppProvider>();
    final price = _effectivePrice;
    final location = _selectedArea.isNotEmpty
        ? '$_selectedArea, $_selectedCity'
        : _selectedCity;

    // Attach schema answers (pruned: hidden conditionals never leak). Each
    // journey adds its reserved keys (_when / _availability / _start) AFTER
    // pruning.
    final attributes = _isRequestFlow
        ? composeRequestAttributes(prunedSchemaAnswers: _submittableAttributes, when: _when)
        : _isOfferFlow
            ? composeOfferAttributes(
                prunedSchemaAnswers: _submittableAttributes, availability: _availability)
            : composeJobAttributes(
                prunedSchemaAnswers: _submittableAttributes, start: _start);
    final schemaVersion = _selectedCategory != null
        ? CategorySchemaService.instance.schemaVersionFor(_selectedCategory!.name)
        : null;

    try {
      await AuthService.ensureCurrentUserInSupabase();

      if (_selectedType == PostType.job) {
        final job = JobModel(
          id: '',
          title: _titleController.text.trim(),
          company: '',
          location: location,
          pay: 'Kes.${formatPriceFull(price)}',
          description: _descriptionController.text.trim(),
          type: _selectedEmploymentType?.displayLabel ?? 'Full-time',
          categoryName: _selectedCategory?.name ?? 'Other',
          // Jobs never carry urgency — the start date lives in attributes.
          urgency: kJobUrgency,
          pricingType: _selectedPricingType,
          attributes: attributes,
          attributesSchemaVersion: schemaVersion,
        );

        final currentUserId = context.read<AuthProvider>().currentUserId;
        final createdJob = await provider.createJob(
          job,
          currentUserId: currentUserId,
          imageFiles: const [],
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
        final locationProvider = context.read<LocationProvider>();
        final post = PostModel(
          id: '',
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          category: _selectedCategory ?? Category.all.last,
          location: location,
          price: price,
          // Offers never carry urgency — availability lives in attributes.
          urgency: _isOfferFlow ? kOfferUrgency : _selectedUrgency,
          type: _selectedType ?? PostType.request,
          pricingType: _selectedPricingType,
          employmentType: _selectedType == PostType.job ? _selectedEmploymentType : null,
          isUrgent: !_isOfferFlow && _selectedUrgency == Urgency.urgent,
          urgentExpiresAt: !_isOfferFlow && _selectedUrgency == Urgency.urgent
              ? DateTime.now().add(const Duration(hours: 1))
              : null,
          latitude: locationProvider.latitude,
          longitude: locationProvider.longitude,
          attributes: attributes,
          attributesSchemaVersion: schemaVersion,
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
