import 'package:flutter/foundation.dart';
import '../models/post_model.dart';
import 'post_service.dart';

/// Splash-time data prefetch.
///
/// main() calls [begin] right after Supabase.initialize — while the native
/// splash is still on screen — so the first-screen network requests are
/// already in flight before the widget tree even builds. AppProvider's initial
/// loads then CONSUME these futures (take-once) instead of issuing new
/// requests: if the response arrived during the splash the feed is populated
/// on the very first frame; if not, the existing skeleton loaders show for the
/// remaining wait, exactly as before.
///
/// Failure-safe by design: every future resolves to null on ANY error (it
/// never throws), and a null result makes AppProvider fall through to its
/// unchanged normal path — connectivity check, offline cache, retry states.
/// With no internet the app therefore behaves byte-for-byte like today.
class StartupPrefetch {
  StartupPrefetch._();

  static Future<List<PostModel>?>? _posts;
  static Future<List<JobModel>?>? _jobs;
  static Future<List<PostModel>?>? _urgent;

  /// Start the first-screen fetches (fire-and-forget). Mirrors the exact
  /// queries AppProvider issues at startup with default filter state.
  static void begin() {
    _posts = _guard('posts', () => PostService.fetchPosts(filters: const PostFilters()));
    _jobs = _guard('jobs', () => PostService.fetchJobs(filters: const PostFilters(type: 'job')));
    _urgent = _guard('urgent', () => PostService.fetchUrgentPosts());
  }

  /// Take-once accessors: return the in-flight future and clear the slot so a
  /// pull-to-refresh or filter change can never be served stale prefetch data.
  static Future<List<PostModel>?>? takePosts() {
    final f = _posts;
    _posts = null;
    return f;
  }

  static Future<List<JobModel>?>? takeJobs() {
    final f = _jobs;
    _jobs = null;
    return f;
  }

  static Future<List<PostModel>?>? takeUrgentPosts() {
    final f = _urgent;
    _urgent = null;
    return f;
  }

  static Future<List<T>?> _guard<T>(String label, Future<List<T>> Function() run) async {
    try {
      return await run();
    } catch (e) {
      debugPrint('[STARTUP_PREFETCH] $label prefetch unavailable ($e) — normal load path takes over');
      return null;
    }
  }
}
