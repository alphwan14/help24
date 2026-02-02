import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';

/// Diagnostic service to help debug image and database issues
class DiagnosticService {
  static final _client = SupabaseConfig.client;

  /// Run full diagnostic check
  static Future<void> runDiagnostics() async {
    debugPrint('');
    debugPrint('═══════════════════════════════════════════');
    debugPrint('🔍 HELP24 DIAGNOSTICS');
    debugPrint('═══════════════════════════════════════════');
    
    await _checkConnection();
    await _checkTables();
    await _checkPostImages();
    await _checkStorageBucket();
    
    debugPrint('═══════════════════════════════════════════');
    debugPrint('');
  }

  static Future<void> _checkConnection() async {
    debugPrint('');
    debugPrint('📡 CONNECTION CHECK');
    try {
      await _client.from('posts').select('id').limit(1);
      debugPrint('   ✅ Supabase connection: OK');
    } catch (e) {
      debugPrint('   ❌ Supabase connection: FAILED - $e');
    }
  }

  static Future<void> _checkTables() async {
    debugPrint('');
    debugPrint('📊 TABLE CHECK');
    
    // Check posts table
    try {
      final posts = await _client.from('posts').select('id, title').limit(3);
      debugPrint('   ✅ posts table: ${(posts as List).length} records found');
      for (final post in posts.take(3)) {
        debugPrint('      - ${post['id'].toString().substring(0, 8)}... : ${post['title']}');
      }
    } catch (e) {
      debugPrint('   ❌ posts table: ERROR - $e');
    }

    // Check post_images table
    try {
      final images = await _client.from('post_images').select('id, post_id, image_url').limit(5);
      debugPrint('   ✅ post_images table: ${(images as List).length} records found');
      for (final img in images.take(5)) {
        debugPrint('      - post_id: ${img['post_id'].toString().substring(0, 8)}...');
        debugPrint('        url: ${img['image_url']}');
      }
    } catch (e) {
      debugPrint('   ❌ post_images table: ERROR - $e');
    }
  }

  static Future<void> _checkPostImages() async {
    debugPrint('');
    debugPrint('🖼️ POST + IMAGES JOIN CHECK');
    
    try {
      // Test the actual query used by fetchPosts
      final response = await _client
          .from('posts')
          .select('id, title, post_images(id, image_url)')
          .limit(5);
      
      final posts = response as List;
      debugPrint('   Query returned ${posts.length} posts');
      
      int postsWithImages = 0;
      int totalImages = 0;
      
      for (final post in posts) {
        final postImages = post['post_images'] as List?;
        final imageCount = postImages?.length ?? 0;
        totalImages += imageCount;
        if (imageCount > 0) postsWithImages++;
        
        final titleStr = post['title'] as String;
        final titlePreview = titleStr.length > 20 ? titleStr.substring(0, 20) : titleStr;
        debugPrint('   - $titlePreview... : $imageCount images');
        if (postImages != null) {
          for (final img in postImages.take(2)) {
            final url = img['image_url']?.toString() ?? 'NULL';
            final urlPreview = url.length > 60 ? '${url.substring(0, 60)}...' : url;
            debugPrint('     └─ $urlPreview');
          }
        }
      }
      
      debugPrint('');
      debugPrint('   📊 Summary:');
      debugPrint('      Total posts checked: ${posts.length}');
      debugPrint('      Posts with images: $postsWithImages');
      debugPrint('      Total images: $totalImages');
      
      if (postsWithImages == 0 && posts.isNotEmpty) {
        debugPrint('');
        debugPrint('   ⚠️ WARNING: Posts exist but no images linked!');
        debugPrint('      Possible causes:');
        debugPrint('      1. Images not being saved to post_images table');
        debugPrint('      2. post_id foreign key not matching');
        debugPrint('      3. post_images table RLS blocking access');
      }
    } catch (e) {
      debugPrint('   ❌ Query ERROR: $e');
    }
  }

  static Future<void> _checkStorageBucket() async {
    debugPrint('');
    debugPrint('📦 STORAGE BUCKET CHECK');
    
    try {
      final files = await _client.storage.from('post-images').list(path: 'posts');
      debugPrint('   ✅ post-images bucket: ${files.length} files in /posts folder');
      
      for (final file in files.take(3)) {
        final publicUrl = _client.storage.from('post-images').getPublicUrl('posts/${file.name}');
        debugPrint('   - ${file.name}');
        debugPrint('     URL: $publicUrl');
      }
      
      if (files.isEmpty) {
        debugPrint('   ⚠️ No files in storage bucket');
      }
    } catch (e) {
      debugPrint('   ❌ Storage check ERROR: $e');
    }
  }

  /// Test upload - creates a small test file to verify storage works
  static Future<bool> testUpload() async {
    debugPrint('');
    debugPrint('🧪 TESTING STORAGE UPLOAD');
    
    try {
      // Create a small test file (1x1 red PNG)
      final testBytes = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
        0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB4, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ];
      
      final testPath = 'test/diagnostic_test.png';
      
      debugPrint('   Uploading test file to: $testPath');
      
      await _client.storage.from('post-images').uploadBinary(
        testPath,
        Uint8List.fromList(testBytes),
        fileOptions: const FileOptions(
          cacheControl: '3600',
          upsert: true,
          contentType: 'image/png',
        ),
      );
      
      final publicUrl = _client.storage.from('post-images').getPublicUrl(testPath);
      debugPrint('   ✅ Upload successful!');
      debugPrint('   Public URL: $publicUrl');
      
      // Clean up test file
      await _client.storage.from('post-images').remove([testPath]);
      debugPrint('   ✅ Test file cleaned up');
      
      return true;
    } catch (e) {
      debugPrint('   ❌ Upload test FAILED: $e');
      return false;
    }
  }

  /// Quick check - returns summary map
  static Future<Map<String, dynamic>> quickCheck() async {
    final results = <String, dynamic>{};
    
    try {
      // Count posts
      final posts = await _client.from('posts').select('id');
      results['posts_count'] = (posts as List).length;
      
      // Count images in DB
      final images = await _client.from('post_images').select('id');
      results['images_in_db'] = (images as List).length;
      
      // Count files in storage
      final files = await _client.storage.from('post-images').list(path: 'posts');
      results['images_in_storage'] = files.length;
      
      // Check if counts match
      results['storage_db_match'] = results['images_in_db'] == results['images_in_storage'];
      
    } catch (e) {
      results['error'] = e.toString();
    }
    
    return results;
  }
}
