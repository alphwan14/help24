import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../config/supabase_config.dart';

/// Service for handling image uploads to Supabase Storage
/// Supports both mobile (File) and web (XFile with bytes) platforms
class StorageService {
  static SupabaseClient get _client => SupabaseConfig.client;
  static const _bucket = SupabaseConfig.postImagesBucket;

  /// Maximum file size in bytes (5MB)
  static const int maxFileSize = 5 * 1024 * 1024;

  /// Allowed image extensions
  static const List<String> allowedExtensions = ['jpg', 'jpeg', 'png', 'gif', 'webp'];

  /// Get file extension from XFile (handles web blob URLs)
  static String _getExtensionFromXFile(XFile file) {
    // Try mimeType first (most reliable on web)
    final mimeType = file.mimeType;
    if (mimeType != null) {
      if (mimeType.contains('jpeg') || mimeType.contains('jpg')) return 'jpg';
      if (mimeType.contains('png')) return 'png';
      if (mimeType.contains('gif')) return 'gif';
      if (mimeType.contains('webp')) return 'webp';
    }
    
    // Try name property
    final name = file.name.toLowerCase();
    for (final ext in allowedExtensions) {
      if (name.endsWith('.$ext')) return ext;
    }
    
    // Try path as last resort
    final path = file.path.toLowerCase();
    for (final ext in allowedExtensions) {
      if (path.endsWith('.$ext')) return ext;
    }
    
    // Default to jpg if we can't determine (image_picker guarantees image)
    return 'jpg';
  }

  /// Upload a single image from XFile (cross-platform)
  /// Returns the public URL of the uploaded image
  static Future<String> uploadImage(XFile file) async {
    try {
      debugPrint('📤 StorageService: Starting upload for ${file.name}');
      
      // Read file as bytes (works on all platforms)
      final bytes = await file.readAsBytes();
      debugPrint('📤 StorageService: Read ${bytes.length} bytes');
      
      // Validate file size
      if (bytes.length > maxFileSize) {
        throw StorageException('File too large. Maximum size is 5MB.');
      }

      // Get extension (handles web blob URLs properly)
      final extension = _getExtensionFromXFile(file);
      debugPrint('📤 StorageService: Extension: $extension');

      // Generate unique filename
      final fileName = '${const Uuid().v4()}.$extension';
      final filePath = 'posts/$fileName';
      debugPrint('📤 StorageService: Uploading to path: $filePath');

      // Determine content type
      final contentType = _getContentType(extension);

      // Upload bytes to Supabase Storage
      debugPrint('📤 StorageService: Uploading to bucket: $_bucket');
      await _client.storage.from(_bucket).uploadBinary(
        filePath,
        bytes,
        fileOptions: FileOptions(
          cacheControl: '3600',
          upsert: false,
          contentType: contentType,
        ),
      );
      debugPrint('📤 StorageService: Upload complete!');

      // Get public URL
      final publicUrl = _client.storage.from(_bucket).getPublicUrl(filePath);
      debugPrint('📤 StorageService: Public URL: $publicUrl');
      return publicUrl;
    } catch (e) {
      debugPrint('❌ StorageService ERROR: $e');
      if (e is StorageException) rethrow;
      throw StorageException('Failed to upload image: $e');
    }
  }

  /// Upload image from bytes directly (useful for web)
  static Future<String> uploadImageBytes(Uint8List bytes, String fileName) async {
    try {
      // Validate file size
      if (bytes.length > maxFileSize) {
        throw StorageException('File too large. Maximum size is 5MB.');
      }

      // Get extension and validate
      final extension = fileName.split('.').last.toLowerCase();
      if (!allowedExtensions.contains(extension)) {
        throw StorageException('Invalid file type. Allowed: ${allowedExtensions.join(", ")}');
      }

      // Generate unique filename
      final uniqueFileName = '${const Uuid().v4()}.$extension';
      final filePath = 'posts/$uniqueFileName';

      // Determine content type
      final contentType = _getContentType(extension);

      // Upload bytes to Supabase Storage
      await _client.storage.from(_bucket).uploadBinary(
        filePath,
        bytes,
        fileOptions: FileOptions(
          cacheControl: '3600',
          upsert: false,
          contentType: contentType,
        ),
      );

      // Get public URL
      final publicUrl = _client.storage.from(_bucket).getPublicUrl(filePath);
      return publicUrl;
    } catch (e) {
      if (e is StorageException) rethrow;
      throw StorageException('Failed to upload image: $e');
    }
  }

  /// Upload multiple images with progress callback
  /// Returns list of public URLs for all successfully uploaded images
  /// Continues uploading even if some images fail
  static Future<List<String>> uploadMultipleImages(
    List<XFile> files, {
    void Function(int completed, int total)? onProgress,
  }) async {
    if (files.isEmpty) return [];

    final urls = <String>[];
    final errors = <String>[];
    
    for (int i = 0; i < files.length; i++) {
      try {
        final url = await uploadImage(files[i]);
        urls.add(url);
      } catch (e) {
        errors.add('Image ${i + 1}: $e');
        // Continue with other uploads even if one fails
      }
      onProgress?.call(i + 1, files.length);
    }

    // Log errors but don't fail completely
    if (errors.isNotEmpty) {
      print('Some images failed to upload: ${errors.join(", ")}');
    }

    return urls;
  }

  /// Upload profile/avatar image for a user. Path: avatars/{userId}.{ext}
  static Future<String> uploadProfileImage(XFile file, String userId) async {
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length > maxFileSize) {
        throw StorageException('Image too large. Maximum size is 5MB.');
      }
      final extension = _getExtensionFromXFile(file);
      final filePath = 'avatars/$userId.$extension';
      final contentType = _getContentType(extension);
      await _client.storage.from(_bucket).uploadBinary(
        filePath,
        bytes,
        fileOptions: FileOptions(
          cacheControl: '3600',
          upsert: true,
          contentType: contentType,
        ),
      );
      return _client.storage.from(_bucket).getPublicUrl(filePath);
    } catch (e) {
      if (e is StorageException) rethrow;
      throw StorageException('Failed to upload profile image: $e');
    }
  }

  /// Delete an image from storage by URL
  static Future<void> deleteImage(String imageUrl) async {
    try {
      // Extract path from URL
      final uri = Uri.parse(imageUrl);
      final pathSegments = uri.pathSegments;
      
      // Find the path after bucket name
      final bucketIndex = pathSegments.indexOf(_bucket);
      if (bucketIndex == -1 || bucketIndex >= pathSegments.length - 1) {
        throw StorageException('Invalid image URL format');
      }
      
      final filePath = pathSegments.sublist(bucketIndex + 1).join('/');
      await _client.storage.from(_bucket).remove([filePath]);
    } catch (e) {
      if (e is StorageException) rethrow;
      throw StorageException('Failed to delete image: $e');
    }
  }

  /// Delete multiple images (best effort - continues on errors)
  static Future<void> deleteMultipleImages(List<String> imageUrls) async {
    for (final url in imageUrls) {
      try {
        await deleteImage(url);
      } catch (e) {
        print('Failed to delete image: $e');
      }
    }
  }

  /// Get content type for file extension
  static String _getContentType(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      default:
        return 'application/octet-stream';
    }
  }

  /// Validate file before upload
  static String? validateFile(XFile file, Uint8List? bytes) {
    // Check extension
    final extension = file.path.split('.').last.toLowerCase();
    if (!allowedExtensions.contains(extension)) {
      return 'Invalid file type. Allowed: ${allowedExtensions.join(", ")}';
    }

    // Check size if bytes provided
    if (bytes != null && bytes.length > maxFileSize) {
      return 'File too large. Maximum size is 5MB.';
    }

    return null; // No error
  }
}

/// Exception for storage-related errors
class StorageException implements Exception {
  final String message;
  StorageException(this.message);
  
  @override
  String toString() => message;
}
