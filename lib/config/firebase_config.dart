import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Firebase configuration with placeholder credentials
/// 
/// HOW TO SET UP:
/// 1. Go to Firebase Console (https://console.firebase.google.com)
/// 2. Select your project
/// 3. Go to Project Settings > General
/// 4. Add your app (Android/iOS/Web) if not already added
/// 5. Copy the configuration values and paste them below
/// 
/// IMPORTANT: Replace the placeholder values with your actual Firebase credentials
class FirebaseConfig {
  // ============================================================
  // FIREBASE CREDENTIALS - REPLACE THESE WITH YOUR ACTUAL VALUES
  // ============================================================
  
  // Web configuration
  static const String webApiKey = 'AIzaSyACUqU_xmKi1fmxfmu2IkokFvlLGOaZ8u0';
  static const String webAppId = '1:454215745233:web:9d4ec935f8d80842aa4ff0';
  static const String webMessagingSenderId = '454215745233';
  static const String webProjectId = 'help24-24410';
  static const String webAuthDomain = 'help24-24410.firebaseapp.com';
  static const String webStorageBucket = 'help24-24410.firebasestorage.app';
  
  // Android configuration
  static const String androidApiKey = 'AIzaSyCIzNruj2eqXtK75Y9cP6Gcf0uZZTAod9E';
  static const String androidAppId = '1:454215745233:android:ecbcd3361eee2d63aa4ff0';
  static const String androidMessagingSenderId = '454215745233-beo1ckg5erre4hit8vvgqimchi73died.apps.googleusercontent.com';
  static const String androidProjectId = 'help24-24410';
  static const String androidStorageBucket = 'help24-24410.firebasestorage.app';
  
  // iOS configuration (if needed)
  static const String iosApiKey = 'AIzaSyAYL65pS4NlHuY3NuajwD9-vSko4a7VFK0';
  static const String iosAppId = '1:454215745233:ios:2001c38b12d5dc82aa4ff0';
  static const String iosMessagingSenderId = '454215745233';
  static const String iosProjectId = 'help24-24410';
  static const String iosBundleId = 'com.example.help24';
  static const String iosStorageBucket = 'help24-24410.firebasestorage.app';
  
  // ============================================================
  
  /// Check if Firebase credentials are configured
  static bool get isConfigured {
    return webApiKey != 'YOUR_WEB_API_KEY' &&
           androidApiKey != 'YOUR_ANDROID_API_KEY';
  }
  
  /// Get Firebase options for current platform
  static FirebaseOptions? get currentPlatformOptions {
    if (!isConfigured) {
      return null;
    }
    
    if (kIsWeb) {
      return FirebaseOptions(
        apiKey: webApiKey,
        appId: webAppId,
        messagingSenderId: webMessagingSenderId,
        projectId: webProjectId,
        authDomain: webAuthDomain,
        storageBucket: webStorageBucket,
      );
    }
    
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return FirebaseOptions(
          apiKey: androidApiKey,
          appId: androidAppId,
          messagingSenderId: androidMessagingSenderId,
          projectId: androidProjectId,
          storageBucket: androidStorageBucket,
        );
      case TargetPlatform.iOS:
        return FirebaseOptions(
          apiKey: iosApiKey,
          appId: iosAppId,
          messagingSenderId: iosMessagingSenderId,
          projectId: iosProjectId,
          iosBundleId: iosBundleId,
          storageBucket: iosStorageBucket,
        );
      default:
        // Fallback to web options for other platforms
        return FirebaseOptions(
          apiKey: webApiKey,
          appId: webAppId,
          messagingSenderId: webMessagingSenderId,
          projectId: webProjectId,
          authDomain: webAuthDomain,
          storageBucket: webStorageBucket,
        );
    }
  }
  
  /// Initialize Firebase if configured
  /// Returns true if Firebase was initialized successfully
  static Future<bool> initialize() async {
    if (!isConfigured) {
      debugPrint('⚠️ Firebase not configured. Auth features will be disabled.');
      debugPrint('   To enable auth, add your Firebase credentials to lib/config/firebase_config.dart');
      return false;
    }
    
    try {
      await Firebase.initializeApp(
        options: currentPlatformOptions,
      );
      // Enable Firestore offline persistence so chats and messages work offline
      FirebaseFirestore.instance.settings = const Settings(
        persistenceEnabled: true,
        cacheSizeBytes: 100 * 1024 * 1024, // 100 MB
      );
      debugPrint('✅ Firebase initialized successfully (Firestore offline enabled)');
      return true;
    } catch (e) {
      debugPrint('❌ Firebase initialization failed: $e');
      return false;
    }
  }
}
