/// The `public.users` row — the SINGLE source of truth for a person on Help24.
///
/// There is no separate provider entity: a provider is a user whose
/// professional profile is complete (see ProfileCompletion / ProviderGate).
/// Trust numbers (rating, jobs, rates, tier) are NOT here — they are derived
/// server-side and served by ReputationService. Never add a counter to this
/// model.
///
/// Pure Dart on purpose (the dead `fromFirestore`/`toFirestore` pair was
/// removed in the Professional Profile milestone — the app has no Firestore
/// users collection and nothing called them), so it is unit-testable and safe
/// to import from the completion registry.
class UserModel {
  final String uid;
  final String name;
  final String email;
  final String? phone;
  final String profileImage;
  final String bio;

  /// Controlled-vocabulary profession KEY (`professions.id`, e.g.
  /// `electrician`). May still hold legacy free text for users who set it
  /// before the controlled selector shipped — always render it through
  /// `ProfessionRegistry.labelFor`, never raw.
  final String profession;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// When the display name was last changed. Owned by the database trigger
  /// (migration 087), never written by the client. Null = never changed.
  final DateTime? nameChangedAt;

  final bool isOnline;
  final DateTime? lastSeen;

  const UserModel({
    required this.uid,
    required this.name,
    required this.email,
    this.phone,
    this.profileImage = '',
    this.bio = '',
    this.profession = '',
    this.createdAt,
    this.updatedAt,
    this.nameChangedAt,
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

  /// Member-since year for the profile header ("Member since 2026").
  String? get memberSinceYear => createdAt?.year.toString();

  UserModel copyWith({
    String? uid,
    String? name,
    String? email,
    String? phone,
    String? profileImage,
    String? bio,
    String? profession,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? nameChangedAt,
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
      profession: profession ?? this.profession,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      nameChangedAt: nameChangedAt ?? this.nameChangedAt,
      isOnline: isOnline ?? this.isOnline,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  /// From a Supabase `users` row.
  factory UserModel.fromSupabase(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    final name = row['name']?.toString() ?? '';
    final email = row['email']?.toString() ?? '';
    final profileImage = row['profile_image']?.toString().trim();
    final avatarUrl = row['avatar_url']?.toString().trim();
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
      profession: row['profession']?.toString() ?? '',
      createdAt: row['created_at'] != null
          ? DateTime.tryParse(row['created_at'].toString())
          : null,
      updatedAt: null,
      // Absent until migration 087 is applied — treated as "never changed",
      // which is the permissive (non-breaking) reading.
      nameChangedAt: row['name_changed_at'] != null
          ? DateTime.tryParse(row['name_changed_at'].toString())
          : null,
      isOnline: false,
      lastSeen: null,
    );
  }
}
