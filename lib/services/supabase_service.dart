import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  static SupabaseClient get client {
    if (!Supabase.instance.initialized) {
      throw Exception('Supabase not initialized! Call Supabase.initialize() first.');
    }
    return Supabase.instance.client;
  }
  
  static bool get isInitialized => Supabase.instance.initialized;
}