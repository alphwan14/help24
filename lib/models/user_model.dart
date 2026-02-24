import 'package:cloud_firestore/cloud_firestore.dart';

/// User profile document in Firestore `users` collection.
/// Document ID = Firebase Auth UID.
class UserModel {
  final String uid;
  final String name;
  final String email;
  final String? phone;
  final String profileImage;
  final String bio;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool isOnline;
  final DateTime? lastSeen;

  const UserModel({
    required this.uid,
    required this.name,
    required this.email,
    this.phone,
    this.profileImage = '',
    this.bio = '',
    this.createdAt,
    this.updatedAt,
    this.isOnline = false,
    this.lastSeen,
  });

  String get displayName =>
      name.trim().isNotEmpty ? name : (email.isNotEmpty ? email.split('@').first : '?');

  String get initials {
    if (name.trim().isNotEmpty) {
      final parts = name.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
      return name.trim()[0].toUpperCase();
    }
    if (email.isNotEmpty) return email[0].toUpperCase();
    return '?';
  }

  UserModel copyWith({
    String? uid,
    String? name,
    String? email,
    String? phone,
    String? profileImage,
    String? bio,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isOnline,
    DateTime? lastSeen,
  }) {
    return UserModel(
      uid: uid ?? this.uid,
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      profileImage: profileImage ?? this.profileImage,
      bio: bio ?? this.bio,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// From Supabase users row (id, name, email, profile_image, avatar_url, ...).
  factory UserModel.fromSupabase(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    final name = row['name']?.toString() ?? '';
    final email = row['email']?.toString() ?? '';
    final profileImage = row['profile_image']?.toString()?.trim();
    final avatarUrl = row['avatar_url']?.toString()?.trim();
    final image = (profileImage != null && profileImage.isNotEmpty)
        ? profileImage
        : (avatarUrl ?? '');
    return UserModel(
      uid: id,
      name: name,
      email: email,
      phone: row['phone_number']?.toString(),
      profileImage: image,
      bio: row['bio']?.toString() ?? '',
      createdAt: row['created_at'] != null
          ? DateTime.tryParse(row['created_at'].toString())
          : null,
      updatedAt: null,
      isOnline: false,
      lastSeen: null,
    );
  }

  /// From Firestore document snapshot.
  factory UserModel.fromFirestore(DocumentSnapshot doc) {
    final data = (doc.data() as Map<String, dynamic>?) ?? {};
    return UserModel(
      uid: doc.id,
      name: data['name']?.toString() ?? '',
      email: data['email']?.toString() ?? '',
      phone: data['phone']?.toString(),
      profileImage: data['profileImage']?.toString() ?? '',
      bio: data['bio']?.toString() ?? '',
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
      updatedAt: data['updatedAt'] is Timestamp
          ? (data['updatedAt'] as Timestamp).toDate()
          : null,
      isOnline: data['isOnline'] == true,
      lastSeen: data['lastSeen'] is Timestamp
          ? (data['lastSeen'] as Timestamp).toDate()
          : null,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'uid': uid,
      'name': name,
      'email': email,
      if (phone != null) 'phone': phone,
      'profileImage': profileImage,
      'bio': bio,
      'isOnline': isOnline,
    };
  }
}
