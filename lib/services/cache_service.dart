import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/post_model.dart';

/// Keys for offline cache in SharedPreferences.
class _Keys {
  static const String posts = 'help24_cache_posts';
  static const String jobs = 'help24_cache_jobs';
}

/// Saves and loads posts/jobs for offline use. When offline and cache exists, UI shows cached data.
class CacheService {
  static SharedPreferences? _prefs;
  static Future<SharedPreferences> get _instance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  static Future<void> savePosts(List<PostModel> posts) async {
    try {
      final prefs = await _instance;
      final list = posts.map((p) => p.toCacheMap()).toList();
      final json = jsonEncode(list);
      await prefs.setString(_Keys.posts, json);
    } catch (e) {
      // Non-critical; ignore
    }
  }

  static Future<List<PostModel>> loadPosts() async {
    try {
      final prefs = await _instance;
      final json = prefs.getString(_Keys.posts);
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List<dynamic>?;
      if (list == null || list.isEmpty) return [];
      return list
          .map((e) => PostModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      return [];
    }
  }

  static Future<void> saveJobs(List<JobModel> jobs) async {
    try {
      final prefs = await _instance;
      final list = jobs.map((j) => j.toCacheMap()).toList();
      final json = jsonEncode(list);
      await prefs.setString(_Keys.jobs, json);
    } catch (e) {
      // Non-critical; ignore
    }
  }

  static Future<List<JobModel>> loadJobs() async {
    try {
      final prefs = await _instance;
      final json = prefs.getString(_Keys.jobs);
      if (json == null || json.isEmpty) return [];
      final list = jsonDecode(json) as List<dynamic>?;
      if (list == null || list.isEmpty) return [];
      return list
          .map((e) => JobModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (e) {
      return [];
    }
  }
}
