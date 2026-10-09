import 'dart:io';

import 'package:help24/services/cache_service.dart';
import 'package:help24/services/chat_media_store.dart';
import 'package:help24/services/chat_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Points [ChatStore] at a REAL SQLite (sqflite_common_ffi) in a fresh temp
/// folder, so tests exercise the actual schema, upserts and queries — not a
/// fake that could agree with a wrong implementation.
///
/// Returns the folder; the database files and the `chat_media` folder are
/// created inside it, which lets a test look at what is on "disk".
Future<Directory> useTestChatStore() async {
  sqfliteFfiInit();
  await ChatStore.instance.closeAllForTest();
  final dir = await Directory.systemTemp.createTemp('chat_store_test_');
  ChatStore.factoryOverride = databaseFactoryFfiNoIsolate;
  ChatStore.directoryOverride = dir.path;
  CacheService.resetMessageMemo();
  ChatMediaStore.resetForTest();
  return dir;
}

/// A process restart: every database closed (nothing deleted) and the
/// in-memory mirror dropped. The next read reopens the file from disk.
Future<void> restartChatStore() async {
  await ChatStore.instance.closeAllForTest();
  CacheService.resetMessageMemo();
}

/// Close everything and delete the temp folder.
Future<void> disposeTestChatStore(Directory dir) async {
  await ChatStore.instance.closeAllForTest();
  try {
    await dir.delete(recursive: true);
  } catch (_) {}
}
