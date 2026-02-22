import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../services/user_profile_service.dart';
import '../theme/app_theme.dart';

/// Edit profile: name, bio, profile image. Email read-only.
/// Saves to Firestore and updates Firebase Auth display name / photo when applicable.
class EditProfileScreen extends StatefulWidget {
  final String uid;
  final UserModel? initialProfile;
  final String emailFromAuth;

  const EditProfileScreen({
    super.key,
    required this.uid,
    this.initialProfile,
    required this.emailFromAuth,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late TextEditingController _nameController;
  late TextEditingController _bioController;
  XFile? _pickedImage;
  Uint8List? _pickedImageBytes;
  String? _uploadedImageUrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final p = widget.initialProfile;
    _nameController = TextEditingController(text: p?.name ?? '');
    _bioController = TextEditingController(text: p?.bio ?? '');
    _uploadedImageUrl = p?.profileImage;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final xFile = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        imageQuality: 85,
      );
      if (xFile != null && mounted) {
        final bytes = await xFile.readAsBytes();
        setState(() {
          _pickedImage = xFile;
          _pickedImageBytes = bytes;
        });
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Name is required');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      String? profileImageUrl = _uploadedImageUrl;
      if (_pickedImage != null) {
        profileImageUrl = await UserProfileService.uploadProfileImage(
          _pickedImage!,
          widget.uid,
        );
      }

      await UserProfileService.ensureProfileDoc(
        uid: widget.uid,
        email: widget.emailFromAuth,
        name: name,
      );
      await UserProfileService.updateProfile(
        uid: widget.uid,
        name: name,
        bio: _bioController.text.trim(),
        profileImage: profileImageUrl,
      );

      if (mounted) {
        final auth = context.read<AuthProvider>();
        await auth.updateProfile(name: name, photoUrl: profileImageUrl);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 20),
                SizedBox(width: 12),
                Text('Profile saved'),
              ],
            ),
            behavior: SnackBarBehavior.floating,
            backgroundColor: AppTheme.successGreen,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } on UserProfileException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasImage = _pickedImageBytes != null || (_uploadedImageUrl != null && _uploadedImageUrl!.isNotEmpty);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.errorRed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Iconsax.warning_2, color: AppTheme.errorRed, size: 20),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_error!, style: const TextStyle(color: AppTheme.errorRed))),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              Center(
                child: GestureDetector(
                  onTap: _pickImage,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 108,
                        height: 108,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                          border: Border.all(
                            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: _pickedImageBytes != null
                              ? Image.memory(
                                  _pickedImageBytes!,
                                  fit: BoxFit.cover,
                                  width: 108,
                                  height: 108,
                                )
                              : (hasImage && _uploadedImageUrl != null)
                                  ? Image.network(
                                      _uploadedImageUrl!,
                                      fit: BoxFit.cover,
                                      width: 108,
                                      height: 108,
                                      errorBuilder: (_, __, ___) => _placeholderIcon(isDark),
                                    )
                                  : _placeholderIcon(isDark),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryAccent,
                            shape: BoxShape.circle,
                            border: Border.all(color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface, width: 2),
                          ),
                          child: const Icon(Iconsax.camera, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                'Name',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                    ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  hintText: 'Your name',
                  prefixIcon: const Icon(Iconsax.user, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  filled: true,
                  fillColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                ),
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: 20),
              Text(
                'Email',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                    ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                initialValue: widget.emailFromAuth,
                readOnly: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Iconsax.sms, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  filled: true,
                  fillColor: (isDark ? AppTheme.darkCard : AppTheme.lightCard).withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Bio',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                    ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _bioController,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: 'Tell others about yourself',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                  filled: true,
                  fillColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: 40),
              SizedBox(
                height: 52,
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primaryAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Save changes'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _placeholderIcon(bool isDark) {
    return Icon(
      Iconsax.user,
      size: 44,
      color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
    );
  }
}
