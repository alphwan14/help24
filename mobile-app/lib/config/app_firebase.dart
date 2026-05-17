import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../firebase_options.dart';

/// Firebase initialization using the FlutterFire-generated firebase_options.dart.
/// Replaces the old manual FirebaseConfig approach.
///
/// Usage:
///   await AppFirebase.initialize();   // call once in bootstrap
///   if (AppFirebase.isReady) { ... }  // guard Firebase operations
class AppFirebase {
  static bool _ready = false;

  /// True once [initialize] has completed successfully.
  static bool get isReady => _ready;

  /// Initialize Firebase with the platform-specific options from
  /// firebase_options.dart and enable Firestore offline persistence.
  /// Returns true on success, false on failure (app continues without Firebase).
  static Future<bool> initialize() async {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      // Offline persistence so messages and posts load from cache when offline.
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: 100 * 1024 * 1024, // 100 MB
      );
      _ready = true;
      debugPrint('Firebase initialized (Firestore offline persistence enabled)');
      return true;
    } catch (e) {
      debugPrint('Firebase initialization failed: $e');
      _ready = false;
      return false;
    }
  }
}
