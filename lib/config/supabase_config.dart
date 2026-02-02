import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase configuration and client initialization
class SupabaseConfig {
  // Supabase credentials
  static const String supabaseUrl = 'https://taohzhnvaitrpxcyjflq.supabase.co';
  static const String supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRhb2h6aG52YWl0cnB4Y3lqZmxxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk5NzEzNjQsImV4cCI6MjA4NTU0NzM2NH0.dHiM5CJMzDIK4u3tzx9yvIsSy7U6Tj8xU9IbIOzHhWk';

  /// Storage bucket name for post images
  static const String postImagesBucket = 'post-images';
  
  /// Track initialization status
  static bool _isInitialized = false;
  static String? _initError;
  
  /// Check if Supabase is initialized
  static bool get isInitialized => _isInitialized;
  
  /// Get initialization error if any
  static String? get initError => _initError;

  /// Initialize Supabase - call this before runApp()
  static Future<bool> initialize() async {
    if (_isInitialized) return true;
    
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        anonKey: supabaseAnonKey,
        debug: kDebugMode,
      );
      _isInitialized = true;
      _initError = null;
      debugPrint('✅ Supabase initialized successfully');
      return true;
    } catch (e) {
      _initError = e.toString();
      debugPrint('❌ Supabase initialization failed: $e');
      return false;
    }
  }

  /// Get the Supabase client instance
  static SupabaseClient get client {
    if (!_isInitialized) {
      throw StateError('Supabase not initialized. Call SupabaseConfig.initialize() first.');
    }
    return Supabase.instance.client;
  }
  
  /// Safely get client (returns null if not initialized)
  static SupabaseClient? get safeClient {
    if (!_isInitialized) return null;
    try {
      return Supabase.instance.client;
    } catch (e) {
      return null;
    }
  }
  
  /// Check if we can connect to Supabase
  static Future<bool> testConnection() async {
    if (!_isInitialized) return false;
    
    try {
      // Simple health check - try to query posts (will fail gracefully if table doesn't exist)
      await client.from('posts').select('id').limit(1);
      return true;
    } catch (e) {
      debugPrint('Supabase connection test failed: $e');
      // Return true if it's just a table not found error (means connection works)
      if (e.toString().contains('PGRST')) {
        return true; // Connection works, just schema issue
      }
      return false;
    }
  }
}
