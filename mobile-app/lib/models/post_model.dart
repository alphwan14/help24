import 'package:flutter/material.dart';

enum PostType { request, offer, job }

/// How price is quoted: per task, per hour, per day, per week, per month.
enum PricingType { task, hour, day, week, month }

extension PricingTypeExtension on PricingType {
  /// Compact rate suffix for dense card text ("KES 25,000/mo").
  String get shortSuffix {
    switch (this) {
      case PricingType.task: return '';
      case PricingType.hour: return '/hr';
      case PricingType.day: return '/day';
      case PricingType.week: return '/wk';
      case PricingType.month: return '/mo';
    }
  }

  String get displayLabel {
    switch (this) {
      case PricingType.task: return 'Per task';
      case PricingType.hour: return 'Per hour';
      case PricingType.day: return 'Per day';
      case PricingType.week: return 'Per week';
      case PricingType.month: return 'Per month';
    }
  }
}

/// Employment type for job posts only.
enum EmploymentType { fullTime, partTime, contract, temporary }

extension EmploymentTypeExtension on EmploymentType {
  String get displayLabel {
    switch (this) {
      case EmploymentType.fullTime: return 'Full-time';
      case EmploymentType.partTime: return 'Part-time';
      case EmploymentType.contract: return 'Contract';
      case EmploymentType.temporary: return 'Temporary';
    }
  }
}

enum Urgency { urgent, soon, flexible }

enum Difficulty { easy, medium, hard, any }

class Category {
  final String name;
  final IconData icon;

  const Category({required this.name, required this.icon});

  // Name-based identity: the server category registry builds fresh instances,
  // and dropdowns need value == item to hold across list refreshes.
  @override
  bool operator ==(Object other) => other is Category && other.name == name;

  @override
  int get hashCode => name.hashCode;

  static List<Category> all = [
    // Home & Property
    Category(name: 'Plumbing', icon: Icons.plumbing),
    Category(name: 'Electrical', icon: Icons.electrical_services),
    Category(name: 'Masonry', icon: Icons.foundation),
    Category(name: 'Carpentry', icon: Icons.handyman),
    Category(name: 'Painting', icon: Icons.format_paint),
    Category(name: 'Welding', icon: Icons.construction),
    // Cleaning & Household
    Category(name: 'House Cleaning', icon: Icons.cleaning_services),
    Category(name: 'Laundry', icon: Icons.local_laundry_service),
    Category(name: 'Gardening', icon: Icons.grass),
    // Security & Transport
    Category(name: 'Security Guard', icon: Icons.security),
    Category(name: 'Driver', icon: Icons.directions_car),
    Category(name: 'Delivery Rider', icon: Icons.delivery_dining),
    // Automotive
    Category(name: 'Mechanic', icon: Icons.car_repair),
    Category(name: 'Car Wash', icon: Icons.local_car_wash),
    // Appliance & Tech Repair
    Category(name: 'Appliance Repair', icon: Icons.kitchen),
    Category(name: 'AC Repair', icon: Icons.ac_unit),
    Category(name: 'Phone Repair', icon: Icons.phone_android),
    Category(name: 'Computer Repair', icon: Icons.computer),
    // Creative & Digital
    Category(name: 'Graphic Design', icon: Icons.brush),
    Category(name: 'Software Development', icon: Icons.code),
    Category(name: 'Photography', icon: Icons.camera_alt),
    Category(name: 'Videography', icon: Icons.videocam),
    // Events & Hospitality
    Category(name: 'Event Planning', icon: Icons.celebration),
    Category(name: 'Catering', icon: Icons.restaurant),
    // Education & Care
    Category(name: 'Tutoring', icon: Icons.school),
    Category(name: 'Babysitting', icon: Icons.child_care),
    Category(name: 'Caregiving', icon: Icons.favorite),
    // Moving & Construction
    Category(name: 'Moving Services', icon: Icons.move_up),
    Category(name: 'Interior Design', icon: Icons.chair),
    Category(name: 'Construction', icon: Icons.architecture),
    Category(name: 'General Labour', icon: Icons.engineering),
    // Fallback
    Category(name: 'Other', icon: Icons.more_horiz),
  ];

  static Category custom(String name) => Category(name: name, icon: Icons.work_outline);

  /// Resolve a stored category name for display. Known names (bundled registry)
  /// keep their icon; any other non-empty name — a provider's custom service
  /// ("TV Repair Technician") or a server-registry category added after this
  /// build shipped — is PRESERVED as-is with a generic icon instead of being
  /// collapsed to 'Other'. Only blank values fall back to 'Other'.
  static Category fromName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return all.last; // 'Other'
    return all.firstWhere(
      (c) => c.name.toLowerCase() == trimmed.toLowerCase(),
      orElse: () => custom(trimmed),
    );
  }

  /// Normalize a user-typed custom service name: trims, collapses repeated
  /// whitespace, and validates (3–40 chars, must contain a letter). Returns
  /// null when the input is not usable as a service name.
  static String? normalizeCustomName(String raw) {
    final collapsed = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.length < 3 || collapsed.length > 40) return null;
    if (!collapsed.contains(RegExp(r'[A-Za-z]'))) return null;
    return collapsed;
  }

  String toJson() => name;
}

// Kenya locations
class KenyaLocation {
  final String city;
  final String area;

  const KenyaLocation({required this.city, required this.area});

  String get fullName => '$area, $city';

  static List<KenyaLocation> all = [
    // Nairobi
    KenyaLocation(city: 'Nairobi', area: 'Westlands'),
    KenyaLocation(city: 'Nairobi', area: 'Kilimani'),
    KenyaLocation(city: 'Nairobi', area: 'Karen'),
    KenyaLocation(city: 'Nairobi', area: 'Lavington'),
    KenyaLocation(city: 'Nairobi', area: 'Kileleshwa'),
    KenyaLocation(city: 'Nairobi', area: 'Parklands'),
    KenyaLocation(city: 'Nairobi', area: 'South B'),
    KenyaLocation(city: 'Nairobi', area: 'South C'),
    KenyaLocation(city: 'Nairobi', area: 'Eastleigh'),
    KenyaLocation(city: 'Nairobi', area: 'CBD'),
    KenyaLocation(city: 'Nairobi', area: 'Kasarani'),
    KenyaLocation(city: 'Nairobi', area: 'Embakasi'),
    KenyaLocation(city: 'Nairobi', area: 'Langata'),
    // Mombasa
    KenyaLocation(city: 'Mombasa', area: 'Nyali'),
    KenyaLocation(city: 'Mombasa', area: 'Bamburi'),
    KenyaLocation(city: 'Mombasa', area: 'Likoni'),
    KenyaLocation(city: 'Mombasa', area: 'Kisauni'),
    KenyaLocation(city: 'Mombasa', area: 'Old Town'),
    KenyaLocation(city: 'Mombasa', area: 'Diani'),
    KenyaLocation(city: 'Mombasa', area: 'Shanzu'),
    // Other Cities
    KenyaLocation(city: 'Nakuru', area: 'Town Centre'),
    KenyaLocation(city: 'Nakuru', area: 'Milimani'),
    KenyaLocation(city: 'Nakuru', area: 'Section 58'),
    KenyaLocation(city: 'Kisumu', area: 'Milimani'),
    KenyaLocation(city: 'Kisumu', area: 'Town Centre'),
    KenyaLocation(city: 'Kisumu', area: 'Mamboleo'),
    KenyaLocation(city: 'Eldoret', area: 'Town Centre'),
    KenyaLocation(city: 'Eldoret', area: 'Elgon View'),
    KenyaLocation(city: 'Thika', area: 'Town Centre'),
    KenyaLocation(city: 'Thika', area: 'Makongeni'),
    KenyaLocation(city: 'Malindi', area: 'Town Centre'),
    KenyaLocation(city: 'Malindi', area: 'Watamu'),
    KenyaLocation(city: 'Voi', area: 'Town Centre'),
    KenyaLocation(city: 'Machakos', area: 'Town Centre'),
    KenyaLocation(city: 'Nyeri', area: 'Town Centre'),
    KenyaLocation(city: 'Meru', area: 'Town Centre'),
    KenyaLocation(city: 'Kitale', area: 'Town Centre'),
    KenyaLocation(city: 'Naivasha', area: 'Town Centre'),
  ];

  static List<String> get cities => all.map((l) => l.city).toSet().toList();
  
  static List<KenyaLocation> getByCity(String city) => 
      all.where((l) => l.city == city).toList();
}

/// Parse display name from joined users row. Never "Unknown" or "Guest": use name, else email prefix, else single char for avatar.
String _userDisplayName(dynamic usersJson) {
  if (usersJson == null || usersJson is! Map) return '?';
  final name = usersJson['name']?.toString()?.trim();
  if (name != null && name.isNotEmpty) return name;
  final email = usersJson['email']?.toString()?.trim();
  if (email != null && email.isNotEmpty) {
    final prefix = email.split('@').first.trim();
    return prefix.isNotEmpty ? prefix : '?';
  }
  return '?';
}

/// Parse avatar URL from joined users row (avatar_url or profile_image).
String _userAvatarUrl(dynamic usersJson) {
  if (usersJson == null || usersJson is! Map) return '';
  final a = usersJson['avatar_url']?.toString()?.trim();
  final b = usersJson['profile_image']?.toString()?.trim();
  return (a != null && a.isNotEmpty) ? a : ((b != null && b.isNotEmpty) ? b : '');
}

/// Returns true if the author has a phone_number (M-Pesa) registered.
bool _userHasPhone(dynamic usersJson) {
  if (usersJson == null || usersJson is! Map) return false;
  final p = usersJson['phone_number']?.toString()?.trim();
  return p != null && p.isNotEmpty;
}

class Application {
  final String id;
  final String postId;
  final String applicantName;
  final String applicantAvatarUrl;
  final String applicantTempId;
  final String applicantUserId;
  final String message;
  final double proposedPrice;
  final DateTime timestamp;

  Application({
    required this.id,
    this.postId = '',
    required this.applicantName,
    this.applicantAvatarUrl = '',
    this.applicantTempId = '',
    this.applicantUserId = '',
    required this.message,
    required this.proposedPrice,
    required this.timestamp,
  });

  /// Create from Supabase JSON (supports joined users(name, profile_image, avatar_url))
  factory Application.fromJson(Map<String, dynamic> json) {
    final users = json['users'];
    return Application(
      id: json['id'] ?? '',
      postId: json['post_id'] ?? '',
      applicantName: _userDisplayName(users),
      applicantAvatarUrl: _userAvatarUrl(users),
      applicantTempId: json['applicant_temp_id'] ?? '',
      applicantUserId: json['applicant_user_id']?.toString() ?? '',
      message: json['message'] ?? '',
      proposedPrice: (json['proposed_price'] ?? 0).toDouble(),
      timestamp: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : DateTime.now(),
    );
  }

  /// Convert to Supabase JSON
  Map<String, dynamic> toJson() {
    return {
      'post_id': postId,
      'applicant_name': applicantName,
      'applicant_temp_id': applicantTempId,
      'applicant_user_id': applicantUserId.isNotEmpty ? applicantUserId : null,
      'message': message,
      'proposed_price': proposedPrice,
    };
  }

  /// Map for offline cache (shape that Application.fromJson expects).
  Map<String, dynamic> toCacheMap() {
    return {
      'id': id,
      'post_id': postId,
      'applicant_temp_id': applicantTempId,
      'applicant_user_id': applicantUserId,
      'message': message,
      'proposed_price': proposedPrice,
      'created_at': timestamp.toIso8601String(),
      'users': {'name': applicantName, 'profile_image': applicantAvatarUrl},
    };
  }
}

class PostModel {
  final String id;
  final String title;
  final String description;
  final Category category;
  final String location;
  final double price;
  final Urgency urgency;
  final PostType type;
  final PricingType pricingType;
  final EmploymentType? employmentType;
  final Difficulty difficulty;
  final double rating;
  /// Author's total review count. When 0 (or null), show "New" instead of a rating.
  final int authorReviewCount;
  final String authorName;
  final String authorAvatar;
  final String authorTempId;
  final String authorUserId;
  final DateTime createdAt;
  final bool isUrgent;
  final DateTime? urgentExpiresAt;
  final double? latitude;
  final double? longitude;
  final List<String> images;
  final List<Application> applications;
  /// User ID of the provider selected by the request author. Null until selected.
  final String? selectedProviderUserId;
  /// True if the offer author has a verified M-Pesa phone on file.
  final bool authorHasPhone;
  /// Lifecycle state of the post: open | assigned | completed | disputed.
  final String status;

  /// Smart Posting: category-specific answers (posts.attributes JSONB).
  /// Empty for legacy posts and categories without a question schema.
  final Map<String, dynamic> attributes;

  /// Version of the category question schema the answers were collected with.
  final int? attributesSchemaVersion;

  /// Enriched AFTER load (not from JSON): true when the job is 'completed' but the
  /// provider payout is still awaiting confirmation (escrow not yet released/refunded).
  /// The card then shows "Finalizing" instead of "Completed" so it never implies the
  /// money is settled. Set by PostService via a batched, best-effort escrow lookup.
  bool payoutInProgress = false;

  PostModel({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.location,
    required this.price,
    required this.urgency,
    required this.type,
    this.pricingType = PricingType.task,
    this.employmentType,
    this.difficulty = Difficulty.medium,
    this.rating = 0,
    this.authorReviewCount = 0,
    this.authorName = '?',
    this.authorAvatar = '',
    this.authorTempId = '',
    this.authorUserId = '',
    DateTime? createdAt,
    this.isUrgent = false,
    this.urgentExpiresAt,
    this.latitude,
    this.longitude,
    this.images = const [],
    this.applications = const [],
    this.selectedProviderUserId,
    this.authorHasPhone = false,
    this.status = 'open',
    this.attributes = const {},
    this.attributesSchemaVersion,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Whether to show a numeric rating (has at least one review). Otherwise show "New".
  bool get hasAuthorRatings => authorReviewCount > 0;

  /// Create from Supabase JSON (with nested post_images, applications, and joined users for author)
  factory PostModel.fromJson(Map<String, dynamic> json) {
    // Parse images from nested post_images relation
    List<String> images = [];
    if (json['post_images'] != null && json['post_images'] is List) {
      for (final img in json['post_images'] as List) {
        if (img != null && img['image_url'] != null && img['image_url'].toString().isNotEmpty) {
          images.add(img['image_url'].toString());
        }
      }
    }

    // Parse applications from nested relation (each may have joined users for applicant)
    List<Application> applications = [];
    if (json['applications'] != null && json['applications'] is List) {
      for (final app in json['applications'] as List) {
        if (app != null) {
          applications.add(Application.fromJson(app as Map<String, dynamic>));
        }
      }
    }

    final authorUsers = json['users'];
    return PostModel(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      category: Category.fromName(json['category'] ?? 'Other'),
      location: json['location'] ?? '',
      price: (json['price'] ?? 0).toDouble(),
      urgency: _parseUrgency(json['urgency']),
      type: _parsePostType(json['type']),
      pricingType: _parsePricingType(json['pricing_type']),
      employmentType: _parseEmploymentType(json['employment_type']),
      difficulty: _parseDifficulty(json['difficulty']),
      // No fabricated rating: default 0. Real ratings come from the reputation
      // endpoint; with no reviews the UI shows "New" (gated by reviewCount).
      rating: (json['rating'] ?? 0).toDouble(),
      authorReviewCount: _parseInt(json['author_review_count'] ?? json['authorReviewCount'], 0),
      authorName: _userDisplayName(authorUsers),
      authorAvatar: _userAvatarUrl(authorUsers),
      authorTempId: json['author_temp_id'] ?? '',
      authorUserId: json['author_user_id']?.toString() ?? '',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : DateTime.now(),
      isUrgent: json['is_urgent'] == true || _parseUrgency(json['urgency']) == Urgency.urgent,
      urgentExpiresAt: json['urgent_expires_at'] != null
          ? DateTime.tryParse(json['urgent_expires_at'].toString())
          : null,
      latitude: (json['latitude'] is num) ? (json['latitude'] as num).toDouble() : null,
      longitude: (json['longitude'] is num) ? (json['longitude'] as num).toDouble() : null,
      images: images,
      applications: applications,
      selectedProviderUserId: json['selected_provider_id']?.toString(),
      authorHasPhone: _userHasPhone(authorUsers),
      status: json['status']?.toString() ?? 'open',
      attributes: json['attributes'] is Map
          ? Map<String, dynamic>.from(json['attributes'] as Map)
          : const {},
      attributesSchemaVersion:
          json['attributes_schema_version'] is int ? json['attributes_schema_version'] as int : null,
    );
  }

  /// Convert to Supabase JSON (for insert/update). author_user_id set by service.
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'description': description,
      'category': category.name,
      'location': location,
      'price': price,
      'urgency': urgency.name,
      'type': type.name,
      'pricing_type': pricingType.name,
      if (employmentType != null) 'employment_type': _employmentTypeToDb(employmentType!),
      'difficulty': difficulty.name,
      'rating': rating,
      'author_temp_id': authorTempId,
      'is_urgent': isUrgent || urgency == Urgency.urgent,
      if (urgentExpiresAt != null) 'urgent_expires_at': urgentExpiresAt!.toIso8601String(),
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      // Only sent when answers exist — inserts keep working on databases where
      // migration 071 has not been applied yet (no schemas → no answers).
      if (attributes.isNotEmpty) 'attributes': attributes,
      if (attributes.isNotEmpty && attributesSchemaVersion != null)
        'attributes_schema_version': attributesSchemaVersion,
    };
  }

  /// Map for offline cache (shape that PostModel.fromJson expects).
  Map<String, dynamic> toCacheMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'category': category.name,
      'location': location,
      'price': price,
      'urgency': urgency.name,
      'type': type.name,
      'pricing_type': pricingType.name,
      if (employmentType != null) 'employment_type': _employmentTypeToDb(employmentType!),
      'difficulty': difficulty.name,
      'rating': rating,
      'author_review_count': authorReviewCount,
      'author_temp_id': authorTempId,
      'author_user_id': authorUserId,
      'is_urgent': isUrgent || urgency == Urgency.urgent,
      if (urgentExpiresAt != null) 'urgent_expires_at': urgentExpiresAt!.toIso8601String(),
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      'created_at': createdAt.toIso8601String(),
      'post_images': images.map((u) => {'image_url': u}).toList(),
      'applications': applications.map((a) => a.toCacheMap()).toList(),
      'users': {'name': authorName, 'profile_image': authorAvatar, if (authorHasPhone) 'phone_number': '1'},
      if (selectedProviderUserId != null) 'selected_provider_id': selectedProviderUserId,
      'status': status,
    };
  }

  static int _parseInt(dynamic value, int fallback) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? fallback;
  }

  static Urgency _parseUrgency(String? value) {
    switch (value?.toLowerCase()) {
      case 'urgent':
        return Urgency.urgent;
      case 'soon':
        return Urgency.soon;
      case 'flexible':
      default:
        return Urgency.flexible;
    }
  }

  static PostType _parsePostType(String? value) {
    switch (value?.toLowerCase()) {
      case 'offer':
        return PostType.offer;
      case 'job':
        return PostType.job;
      case 'request':
      default:
        return PostType.request;
    }
  }

  static PricingType _parsePricingType(String? value) {
    switch (value?.toLowerCase()) {
      case 'hour': return PricingType.hour;
      case 'day': return PricingType.day;
      case 'week': return PricingType.week;
      case 'month': return PricingType.month;
      case 'task':
      default: return PricingType.task;
    }
  }

  static EmploymentType? _parseEmploymentType(String? value) {
    if (value == null || value.isEmpty) return null;
    switch (value.toLowerCase()) {
      case 'full_time': return EmploymentType.fullTime;
      case 'part_time': return EmploymentType.partTime;
      case 'contract': return EmploymentType.contract;
      case 'temporary': return EmploymentType.temporary;
      default: return null;
    }
  }

  static String _employmentTypeToDb(EmploymentType e) {
    switch (e) {
      case EmploymentType.fullTime: return 'full_time';
      case EmploymentType.partTime: return 'part_time';
      case EmploymentType.contract: return 'contract';
      case EmploymentType.temporary: return 'temporary';
    }
  }

  static Difficulty _parseDifficulty(String? value) {
    switch (value?.toLowerCase()) {
      case 'easy':
        return Difficulty.easy;
      case 'hard':
        return Difficulty.hard;
      case 'any':
        return Difficulty.any;
      case 'medium':
      default:
        return Difficulty.medium;
    }
  }

  PostModel copyWith({
    String? id,
    String? title,
    String? description,
    Category? category,
    String? location,
    double? price,
    Urgency? urgency,
    PostType? type,
    PricingType? pricingType,
    EmploymentType? employmentType,
    Difficulty? difficulty,
    double? rating,
    int? authorReviewCount,
    String? authorName,
    String? authorAvatar,
    String? authorTempId,
    String? authorUserId,
    DateTime? createdAt,
    bool? isUrgent,
    DateTime? urgentExpiresAt,
    double? latitude,
    double? longitude,
    List<String>? images,
    List<Application>? applications,
    String? selectedProviderUserId,
    bool? authorHasPhone,
    String? status,
  }) {
    return PostModel(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      category: category ?? this.category,
      location: location ?? this.location,
      price: price ?? this.price,
      urgency: urgency ?? this.urgency,
      type: type ?? this.type,
      pricingType: pricingType ?? this.pricingType,
      employmentType: employmentType ?? this.employmentType,
      difficulty: difficulty ?? this.difficulty,
      rating: rating ?? this.rating,
      authorReviewCount: authorReviewCount ?? this.authorReviewCount,
      authorName: authorName ?? this.authorName,
      authorAvatar: authorAvatar ?? this.authorAvatar,
      authorTempId: authorTempId ?? this.authorTempId,
      authorUserId: authorUserId ?? this.authorUserId,
      createdAt: createdAt ?? this.createdAt,
      isUrgent: isUrgent ?? this.isUrgent,
      urgentExpiresAt: urgentExpiresAt ?? this.urgentExpiresAt,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      images: images ?? this.images,
      applications: applications ?? this.applications,
      selectedProviderUserId: selectedProviderUserId ?? this.selectedProviderUserId,
      authorHasPhone: authorHasPhone ?? this.authorHasPhone,
      status: status ?? this.status,
    );
  }

  Color get urgencyColor {
    switch (urgency) {
      case Urgency.urgent:
        return const Color(0xFFE53935);
      case Urgency.soon:
        return const Color(0xFFFF9800);
      case Urgency.flexible:
        return const Color(0xFF4CAF50);
    }
  }

  String get urgencyText {
    switch (urgency) {
      case Urgency.urgent:
        return 'Urgent';
      case Urgency.soon:
        return 'Soon';
      case Urgency.flexible:
        return 'Flexible';
    }
  }

  /// Display label for post type — shown on feed cards and in the detail sheet.
  String get typeDisplayLabel {
    switch (type) {
      case PostType.request: return 'Request';
      case PostType.offer: return 'Offer';
      case PostType.job: return 'Job';
    }
  }

  /// Badge color for post type.
  Color get typeBadgeColor {
    switch (type) {
      case PostType.request: return const Color(0xFF2196F3); // blue
      case PostType.offer: return const Color(0xFF4CAF50);   // green
      case PostType.job: return const Color(0xFF9C27B0);    // purple
    }
  }

  Color get difficultyColor {
    switch (difficulty) {
      case Difficulty.easy:
        return const Color(0xFF4CAF50);
      case Difficulty.medium:
        return const Color(0xFFFF9800);
      case Difficulty.hard:
        return const Color(0xFFE53935);
      case Difficulty.any:
        return const Color(0xFF6B7280);
    }
  }

  String get difficultyText {
    switch (difficulty) {
      case Difficulty.easy:
        return 'Easy';
      case Difficulty.medium:
        return 'Medium';
      case Difficulty.hard:
        return 'Hard';
      case Difficulty.any:
        return 'Any';
    }
  }
}

class JobModel {
  final String id;
  final String title;
  final String authorName;
  final String authorAvatarUrl;
  final String authorUserId;
  final String company;
  final String location;
  final String pay;
  final String type;
  final String description;
  final String authorTempId;
  final DateTime postedAt;
  final List<String> images;
  final List<Application> applications;
  final bool hasApplied;
  final double rating;
  final int authorReviewCount;
  final Difficulty difficulty;
  final Urgency urgency;
  final String categoryName;

  /// How the pay is quoted (salary period): month for typical employment,
  /// day/week for casual work. Maps to posts.pricing_type.
  final PricingType pricingType;

  /// Smart Posting: category-specific answers (posts.attributes JSONB).
  final Map<String, dynamic> attributes;
  final int? attributesSchemaVersion;

  JobModel({
    required this.id,
    required this.title,
    this.authorName = '?',
    this.authorAvatarUrl = '',
    this.authorUserId = '',
    this.company = '?',
    required this.location,
    required this.pay,
    this.type = 'Full-time',
    this.description = '',
    this.authorTempId = '',
    DateTime? postedAt,
    this.images = const [],
    this.applications = const [],
    this.hasApplied = false,
    this.rating = 0,
    this.authorReviewCount = 0,
    this.difficulty = Difficulty.any,
    this.urgency = Urgency.flexible,
    this.categoryName = 'Job',
    this.pricingType = PricingType.task,
    this.attributes = const {},
    this.attributesSchemaVersion,
  }) : postedAt = postedAt ?? DateTime.now();

  bool get hasAuthorRatings => authorReviewCount > 0;

  String get urgencyText {
    switch (urgency) {
      case Urgency.urgent: return 'Urgent';
      case Urgency.soon: return 'Soon';
      case Urgency.flexible: return 'Flexible';
    }
  }

  Color get urgencyColor {
    switch (urgency) {
      case Urgency.urgent: return const Color(0xFFE53935);
      case Urgency.soon: return const Color(0xFFFF9800);
      case Urgency.flexible: return const Color(0xFF4CAF50);
    }
  }

  String get difficultyText {
    switch (difficulty) {
      case Difficulty.easy: return 'Easy';
      case Difficulty.medium: return 'Medium';
      case Difficulty.hard: return 'Hard';
      case Difficulty.any: return 'Any';
    }
  }

  /// Create from Supabase JSON
  factory JobModel.fromJson(Map<String, dynamic> json) {
    // Parse images from nested post_images relation
    List<String> images = [];
    if (json['post_images'] != null && json['post_images'] is List) {
      for (final img in json['post_images'] as List) {
        if (img != null && img['image_url'] != null && img['image_url'].toString().isNotEmpty) {
          images.add(img['image_url'].toString());
        }
      }
    }

    // Parse applications from nested relation
    List<Application> applications = [];
    if (json['applications'] != null && json['applications'] is List) {
      for (final app in json['applications'] as List) {
        if (app != null) {
          applications.add(Application.fromJson(app as Map<String, dynamic>));
        }
      }
    }

    final authorUsers = json['users'];
    final name = _userDisplayName(authorUsers);
    // R-4: jobs carry a real salary period (posts.pricing_type) — surface it
    // as a compact suffix ("KES 25,000/mo").
    final pricingType = PostModel._parsePricingType(json['pricing_type'] as String?);
    return JobModel(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      authorName: name,
      authorAvatarUrl: _userAvatarUrl(authorUsers),
      authorUserId: json['author_user_id']?.toString() ?? '',
      company: name,
      location: json['location'] ?? '',
      pay: 'KES ${json['price'] ?? 0}${pricingType.shortSuffix}',
      type: _employmentTypeToDisplay(json['employment_type']) ?? json['type']?.toString() ?? 'Full-time',
      description: json['description'] ?? '',
      authorTempId: json['author_temp_id'] ?? '',
      postedAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : DateTime.now(),
      images: images,
      applications: applications,
      rating: (json['rating'] ?? 0).toDouble(),
      authorReviewCount: PostModel._parseInt(json['author_review_count'] ?? json['authorReviewCount'], 0),
      difficulty: _parseJobDifficulty(json['difficulty']),
      urgency: _parseUrgency(json['urgency']),
      categoryName: json['category']?.toString() ?? 'Job',
      pricingType: pricingType,
      attributes: json['attributes'] is Map
          ? Map<String, dynamic>.from(json['attributes'] as Map)
          : const {},
    );
  }

  static Difficulty _parseJobDifficulty(dynamic value) {
    if (value == null) return Difficulty.any;
    switch (value.toString().toLowerCase()) {
      case 'easy': return Difficulty.easy;
      case 'hard': return Difficulty.hard;
      case 'medium': return Difficulty.medium;
      default: return Difficulty.any;
    }
  }

  static Urgency _parseUrgency(dynamic value) {
    if (value == null) return Urgency.flexible;
    final s = value.toString().toLowerCase();
    if (s == 'urgent') return Urgency.urgent;
    if (s == 'soon') return Urgency.soon;
    return Urgency.flexible;
  }

  static String? _employmentTypeToDisplay(dynamic value) {
    if (value == null) return null;
    switch (value.toString().toLowerCase()) {
      case 'full_time': return 'Full-time';
      case 'part_time': return 'Part-time';
      case 'contract': return 'Contract';
      case 'temporary': return 'Temporary';
      default: return null;
    }
  }

  /// Convert to Supabase JSON. author_user_id set by service.
  Map<String, dynamic> toJson() {
    double price = 0;
    final priceMatch = RegExp(r'[\d,]+').firstMatch(pay);
    if (priceMatch != null) {
      price = double.tryParse(priceMatch.group(0)!.replaceAll(',', '')) ?? 0;
    }
    final employmentType = _displayToEmploymentType(type);
    return {
      'title': title,
      'description': description,
      'category': categoryName,
      'location': location,
      'price': price,
      'urgency': urgency.name,
      'type': 'job',
      'pricing_type': pricingType.name,
      if (employmentType != null) 'employment_type': employmentType,
      'difficulty': difficulty.name,
      'author_temp_id': authorTempId,
      // Only sent when answers exist — see PostModel.toJson.
      if (attributes.isNotEmpty) 'attributes': attributes,
      if (attributes.isNotEmpty && attributesSchemaVersion != null)
        'attributes_schema_version': attributesSchemaVersion,
    };
  }

  static String? _displayToEmploymentType(String display) {
    switch (display.toLowerCase()) {
      case 'full-time': return 'full_time';
      case 'part-time': return 'part_time';
      case 'contract': return 'contract';
      case 'temporary': return 'temporary';
      default: return null;
    }
  }

  /// Map for offline cache (shape that JobModel.fromJson expects).
  Map<String, dynamic> toCacheMap() {
    return {
      'id': id,
      'title': title,
      'author_user_id': authorUserId,
      'location': location,
      'pay': pay,
      'type': type,
      'description': description,
      'author_temp_id': authorTempId,
      'created_at': postedAt.toIso8601String(),
      'post_images': images.map((u) => {'image_url': u}).toList(),
      'applications': applications.map((a) => a.toCacheMap()).toList(),
      'users': {'name': authorName, 'profile_image': authorAvatarUrl},
      'category': categoryName,
      'difficulty': difficulty.name,
      'urgency': urgency.name,
      'rating': rating,
      'author_review_count': authorReviewCount,
    };
  }

  JobModel copyWith({
    String? id,
    String? title,
    String? authorName,
    String? authorAvatarUrl,
    String? authorUserId,
    String? company,
    String? location,
    String? pay,
    String? type,
    String? description,
    String? authorTempId,
    DateTime? postedAt,
    List<String>? images,
    List<Application>? applications,
    bool? hasApplied,
    double? rating,
    int? authorReviewCount,
    Difficulty? difficulty,
    Urgency? urgency,
    String? categoryName,
  }) {
    return JobModel(
      id: id ?? this.id,
      title: title ?? this.title,
      authorName: authorName ?? this.authorName,
      authorAvatarUrl: authorAvatarUrl ?? this.authorAvatarUrl,
      authorUserId: authorUserId ?? this.authorUserId,
      company: company ?? this.company,
      location: location ?? this.location,
      pay: pay ?? this.pay,
      type: type ?? this.type,
      description: description ?? this.description,
      authorTempId: authorTempId ?? this.authorTempId,
      postedAt: postedAt ?? this.postedAt,
      images: images ?? this.images,
      applications: applications ?? this.applications,
      hasApplied: hasApplied ?? this.hasApplied,
      rating: rating ?? this.rating,
      authorReviewCount: authorReviewCount ?? this.authorReviewCount,
      difficulty: difficulty ?? this.difficulty,
      urgency: urgency ?? this.urgency,
      categoryName: categoryName ?? this.categoryName,
    );
  }
}

/// Message type: text, image, file, location (static), live_location (updating).
class Message {
  final String id;
  final String conversationId;
  final String senderId;
  final String receiverId;
  final String text;
  final DateTime timestamp;
  final bool isMe;
  final String type;
  final double? latitude;
  final double? longitude;
  final DateTime? liveUntil;
  final String? attachmentUrl;
  /// 'sent' | 'seen'
  final String status;
  final DateTime? seenAt;
  /// True when the sender deleted this message for everyone.
  /// Row is kept in DB; UI renders a tombstone instead of the content.
  final bool deletedForEveryone;

  /// Reply threading — null when this message is not a reply.
  final String? replyToId;
  /// Denormalised: display name of the sender of the quoted message.
  final String? replyToSender;
  /// Denormalised: first ~200 chars of the quoted message text.
  final String? replyToPreview;

  Message({
    required this.id,
    this.conversationId = '',
    required this.senderId,
    this.receiverId = '',
    required this.text,
    required this.timestamp,
    required this.isMe,
    this.type = 'text',
    this.latitude,
    this.longitude,
    this.liveUntil,
    this.attachmentUrl,
    this.status = 'sent',
    this.seenAt,
    this.deletedForEveryone = false,
    this.replyToId,
    this.replyToSender,
    this.replyToPreview,
  });

  bool get isLocation => type == 'location' || type == 'live_location';
  bool get isLiveLocation => type == 'live_location';
  bool get isImage => type == 'image';
  bool get isFile => type == 'file';
  bool get hasValidCoordinates =>
      latitude != null && longitude != null && latitude!.abs() <= 90 && longitude!.abs() <= 180;

  /// Create from Supabase JSON (supports sender_id, message, type, latitude, longitude, live_until, attachment_url)
  factory Message.fromJson(Map<String, dynamic> json, String currentUserId) {
    final senderId = (json['sender_id'] ?? json['sender_temp_id'] ?? '') as String;
    final text = (json['message'] ?? json['content'] ?? '') as String;
    final type = (json['type'] ?? 'text') as String;
    double? lat = json['latitude'] != null ? (json['latitude'] as num).toDouble() : null;
    double? lng = json['longitude'] != null ? (json['longitude'] as num).toDouble() : null;
    DateTime? liveUntil = json['live_until'] != null
        ? DateTime.tryParse(json['live_until'].toString())
        : null;
    final attachmentUrl = json['attachment_url']?.toString();
    final status = (json['status'] ?? 'sent') as String;
    final seenAt = json['seen_at'] != null
        ? DateTime.tryParse(json['seen_at'].toString())
        : null;
    final deletedForEveryone = json['deleted_for_everyone'] as bool? ?? false;
    final replyToId      = json['reply_to_id']?.toString();
    final replyToSender  = json['reply_to_sender']?.toString();
    final replyToPreview = json['reply_to_preview']?.toString();
    return Message(
      id: (json['id'] ?? '').toString(),
      conversationId: (json['conversation_id'] ?? '').toString(),
      senderId: senderId,
      receiverId: (json['receiver_temp_id'] ?? '').toString(),
      text: text,
      timestamp: json['created_at'] != null
          ? DateTime.parse(json['created_at'].toString())
          : DateTime.now(),
      isMe: senderId == currentUserId,
      type: type,
      latitude: lat,
      longitude: lng,
      liveUntil: liveUntil,
      attachmentUrl: attachmentUrl,
      status: status,
      seenAt: seenAt,
      deletedForEveryone: deletedForEveryone,
      replyToId: replyToId,
      replyToSender: replyToSender,
      replyToPreview: replyToPreview,
    );
  }

  Message copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    String? receiverId,
    String? text,
    DateTime? timestamp,
    bool? isMe,
    String? type,
    double? latitude,
    double? longitude,
    DateTime? liveUntil,
    String? attachmentUrl,
    String? status,
    DateTime? seenAt,
    bool? deletedForEveryone,
    String? replyToId,
    String? replyToSender,
    String? replyToPreview,
  }) {
    return Message(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      text: text ?? this.text,
      timestamp: timestamp ?? this.timestamp,
      isMe: isMe ?? this.isMe,
      type: type ?? this.type,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      liveUntil: liveUntil ?? this.liveUntil,
      attachmentUrl: attachmentUrl ?? this.attachmentUrl,
      status: status ?? this.status,
      seenAt: seenAt ?? this.seenAt,
      deletedForEveryone: deletedForEveryone ?? this.deletedForEveryone,
      replyToId: replyToId ?? this.replyToId,
      replyToSender: replyToSender ?? this.replyToSender,
      replyToPreview: replyToPreview ?? this.replyToPreview,
    );
  }

  /// Convert to Supabase JSON (new messages table schema)
  Map<String, dynamic> toJson() {
    return {
      'conversation_id': conversationId,
      'sender_id': senderId,
      'message': text,
      if (type != 'text') 'type': type,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (liveUntil != null) 'live_until': liveUntil!.toIso8601String(),
    };
  }

  /// For offline cache: map that fromJson(..., currentUserId) can read.
  Map<String, dynamic> toCacheMap() {
    return {
      'id': id,
      'sender_id': senderId,
      'content': text,
      'message': text,
      'created_at': timestamp.toIso8601String(),
      'type': type,
      'status': status,
      if (seenAt != null) 'seen_at': seenAt!.toIso8601String(),
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (liveUntil != null) 'live_until': liveUntil!.toIso8601String(),
      if (attachmentUrl != null) 'attachment_url': attachmentUrl,
    };
  }
}

class Conversation {
  final String id;
  final String participantId;
  final String userName;
  final String userAvatar;
  final String lastMessage;
  final DateTime lastMessageTime;
  final int unreadCount;
  final List<Message> messages;
  /// Optional post id when chat is scoped to a post (for navigating to post from chat).
  final String? postId;
  /// Human-readable title of the post this chat belongs to (fetched via join).
  final String? postTitle;

  Conversation({
    required this.id,
    this.participantId = '',
    required this.userName,
    this.userAvatar = '',
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.messages = const [],
    this.postId,
    this.postTitle,
  });

  Conversation copyWith({
    String? id,
    String? participantId,
    String? userName,
    String? userAvatar,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    List<Message>? messages,
    String? postId,
    String? postTitle,
  }) {
    return Conversation(
      id: id ?? this.id,
      participantId: participantId ?? this.participantId,
      userName: userName ?? this.userName,
      userAvatar: userAvatar ?? this.userAvatar,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      messages: messages ?? this.messages,
      postId: postId ?? this.postId,
      postTitle: postTitle ?? this.postTitle,
    );
  }

  /// For offline cache.
  Map<String, dynamic> toCacheMap() {
    return {
      'id': id,
      'participant_id': participantId,
      'user_name': userName,
      'user_avatar': userAvatar,
      'last_message': lastMessage,
      'last_message_time': lastMessageTime.toIso8601String(),
      'unread_count': unreadCount,
      'post_id': postId,
      if (postTitle != null) 'post_title': postTitle,
    };
  }

  /// From cache map (no messages; load messages separately).
  static Conversation fromCacheMap(Map<String, dynamic> map) {
    return Conversation(
      id: (map['id'] ?? '').toString(),
      participantId: (map['participant_id'] ?? '').toString(),
      userName: (map['user_name'] ?? '').toString(),
      userAvatar: (map['user_avatar'] ?? '').toString(),
      lastMessage: (map['last_message'] ?? '').toString(),
      lastMessageTime: map['last_message_time'] != null
          ? DateTime.tryParse(map['last_message_time'].toString()) ?? DateTime.now()
          : DateTime.now(),
      unreadCount: (map['unread_count'] is int) ? map['unread_count'] as int : 0,
      postId: map['post_id']?.toString(),
      postTitle: map['post_title']?.toString(),
    );
  }
}
