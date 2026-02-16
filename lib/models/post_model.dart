import 'package:flutter/material.dart';

enum PostType { request, offer, job }

enum Urgency { urgent, soon, flexible }

enum Difficulty { easy, medium, hard, any }

class Category {
  final String name;
  final IconData icon;

  const Category({required this.name, required this.icon});

  static List<Category> all = [
    Category(name: 'Garden', icon: Icons.grass),
    Category(name: 'Design', icon: Icons.brush),
    Category(name: 'IT', icon: Icons.computer),
    Category(name: 'Events', icon: Icons.celebration),
    Category(name: 'Plumbing', icon: Icons.plumbing),
    Category(name: 'Painting', icon: Icons.format_paint),
    Category(name: 'Cleaning', icon: Icons.cleaning_services),
    Category(name: 'Delivery', icon: Icons.local_shipping),
    Category(name: 'Moving', icon: Icons.move_up),
    Category(name: 'Repair', icon: Icons.build),
    Category(name: 'Teaching', icon: Icons.school),
    Category(name: 'Beauty', icon: Icons.spa),
    Category(name: 'Cooking', icon: Icons.restaurant),
    Category(name: 'Driving', icon: Icons.directions_car),
    Category(name: 'Security', icon: Icons.security),
    Category(name: 'Other', icon: Icons.more_horiz),
  ];

  static Category custom(String name) => Category(name: name, icon: Icons.work_outline);

  /// Find category by name, returns 'Other' if not found
  static Category fromName(String name) {
    return all.firstWhere(
      (c) => c.name.toLowerCase() == name.toLowerCase(),
      orElse: () => all.last, // 'Other'
    );
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

class Application {
  final String id;
  final String postId;
  final String applicantName;
  final String applicantTempId;
  final String message;
  final double proposedPrice;
  final DateTime timestamp;

  Application({
    required this.id,
    this.postId = '',
    required this.applicantName,
    this.applicantTempId = '',
    required this.message,
    required this.proposedPrice,
    required this.timestamp,
  });

  /// Create from Supabase JSON
  factory Application.fromJson(Map<String, dynamic> json) {
    return Application(
      id: json['id'] ?? '',
      postId: json['post_id'] ?? '',
      applicantName: json['applicant_name'] ?? 'Anonymous',
      applicantTempId: json['applicant_temp_id'] ?? '',
      message: json['message'] ?? '',
      proposedPrice: (json['proposed_price'] ?? 0).toDouble(),
      timestamp: json['created_at'] != null 
          ? DateTime.parse(json['created_at']) 
          : DateTime.now(),
    );
  }

  /// Convert to Supabase JSON
  Map<String, dynamic> toJson() {
    return {
      'post_id': postId,
      'applicant_name': applicantName,
      'applicant_temp_id': applicantTempId,
      'message': message,
      'proposed_price': proposedPrice,
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
  final Difficulty difficulty;
  final double rating;
  final String authorName;
  final String authorAvatar;
  final String authorTempId;
  final DateTime createdAt;
  final List<String> images;
  final List<Application> applications;

  PostModel({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.location,
    required this.price,
    required this.urgency,
    required this.type,
    this.difficulty = Difficulty.medium,
    this.rating = 4.5,
    this.authorName = 'Anonymous',
    this.authorAvatar = '',
    this.authorTempId = '',
    DateTime? createdAt,
    this.images = const [],
    this.applications = const [],
  }) : createdAt = createdAt ?? DateTime.now();

  /// Create from Supabase JSON (with nested images and applications)
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

    // Parse applications from nested relation
    List<Application> applications = [];
    if (json['applications'] != null && json['applications'] is List) {
      for (final app in json['applications'] as List) {
        if (app != null) {
          applications.add(Application.fromJson(app as Map<String, dynamic>));
        }
      }
    }

    return PostModel(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      category: Category.fromName(json['category'] ?? 'Other'),
      location: json['location'] ?? '',
      price: (json['price'] ?? 0).toDouble(),
      urgency: _parseUrgency(json['urgency']),
      type: _parsePostType(json['type']),
      difficulty: _parseDifficulty(json['difficulty']),
      rating: (json['rating'] ?? 4.5).toDouble(),
      authorName: json['author_name'] ?? 'Anonymous',
      authorAvatar: json['author_avatar']?.toString() ?? '',
      authorTempId: json['author_temp_id'] ?? '',
      createdAt: json['created_at'] != null 
          ? DateTime.parse(json['created_at']) 
          : DateTime.now(),
      images: images,
      applications: applications,
    );
  }

  /// Convert to Supabase JSON (for insert/update)
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'description': description,
      'category': category.name,
      'location': location,
      'price': price,
      'urgency': urgency.name,
      'type': type.name,
      'difficulty': difficulty.name,
      'rating': rating,
      'author_name': authorName,
      'author_temp_id': authorTempId,
    };
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
    Difficulty? difficulty,
    double? rating,
    String? authorName,
    String? authorAvatar,
    String? authorTempId,
    DateTime? createdAt,
    List<String>? images,
    List<Application>? applications,
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
      difficulty: difficulty ?? this.difficulty,
      rating: rating ?? this.rating,
      authorName: authorName ?? this.authorName,
      authorAvatar: authorAvatar ?? this.authorAvatar,
      authorTempId: authorTempId ?? this.authorTempId,
      createdAt: createdAt ?? this.createdAt,
      images: images ?? this.images,
      applications: applications ?? this.applications,
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

  JobModel({
    required this.id,
    required this.title,
    required this.company,
    required this.location,
    required this.pay,
    this.type = 'Full-time',
    this.description = '',
    this.authorTempId = '',
    DateTime? postedAt,
    this.images = const [],
    this.applications = const [],
    this.hasApplied = false,
  }) : postedAt = postedAt ?? DateTime.now();

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

    return JobModel(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      company: json['author_name'] ?? 'Company',
      location: json['location'] ?? '',
      pay: 'KES ${json['price'] ?? 0}',
      type: json['difficulty'] ?? 'Full-time',
      description: json['description'] ?? '',
      authorTempId: json['author_temp_id'] ?? '',
      postedAt: json['created_at'] != null 
          ? DateTime.parse(json['created_at']) 
          : DateTime.now(),
      images: images,
      applications: applications,
    );
  }

  /// Convert to Supabase JSON
  Map<String, dynamic> toJson() {
    // Parse price from pay string (e.g., "KES 50000" -> 50000)
    double price = 0;
    final priceMatch = RegExp(r'[\d,]+').firstMatch(pay);
    if (priceMatch != null) {
      price = double.tryParse(priceMatch.group(0)!.replaceAll(',', '')) ?? 0;
    }

    return {
      'title': title,
      'description': '$description\n\nJob Type: $type', // Include job type in description
      'category': 'Other', // Jobs use generic category
      'location': location,
      'price': price,
      'urgency': 'flexible',
      'type': 'job',
      'difficulty': 'medium', // Use valid difficulty value
      'author_name': company,
      'author_temp_id': authorTempId,
    };
  }

  JobModel copyWith({
    String? id,
    String? title,
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
  }) {
    return JobModel(
      id: id ?? this.id,
      title: title ?? this.title,
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
    );
  }
}

/// Message type: text, image, location (static), live_location (updating).
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
  });

  bool get isLocation => type == 'location' || type == 'live_location';
  bool get isLiveLocation => type == 'live_location';
  bool get hasValidCoordinates =>
      latitude != null && longitude != null && latitude!.abs() <= 90 && longitude!.abs() <= 180;

  /// Create from Supabase JSON (supports new schema: sender_id, message, type, latitude, longitude, live_until)
  factory Message.fromJson(Map<String, dynamic> json, String currentUserId) {
    final senderId = (json['sender_id'] ?? json['sender_temp_id'] ?? '') as String;
    final text = (json['message'] ?? json['content'] ?? '') as String;
    final type = (json['type'] ?? 'text') as String;
    double? lat = json['latitude'] != null ? (json['latitude'] as num).toDouble() : null;
    double? lng = json['longitude'] != null ? (json['longitude'] as num).toDouble() : null;
    DateTime? liveUntil = json['live_until'] != null
        ? DateTime.tryParse(json['live_until'].toString())
        : null;
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

  Conversation({
    required this.id,
    this.participantId = '',
    required this.userName,
    this.userAvatar = '',
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.messages = const [],
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
    );
  }
}
