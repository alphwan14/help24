import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/config/api_config.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/services/chat_attachments.dart';
import 'package:help24/services/chat_documents.dart';
import 'package:http/http.dart' as http;

/// CHAT DOCUMENTS OPEN LIKE CHAT PHOTOS.
///
/// Measured on the S20+ (2026-10-04): a 778-byte PDF took 3–4 s to open and a
/// 9 MB one ~9 s, every time, because each open minted a one-time browser
/// link, burnt it in a Durable Object, followed a 303 and downloaded the file
/// again. These tests pin the replacement: one authenticated download into
/// app-private storage, then every open from the phone with no network.
void main() {
  const pdf = '1a1a1a1a-0000-4000-8000-000000000001';
  const pdf2 = '2b2b2b2b-0000-4000-8000-000000000002';
  const docx = '3c3c3c3c-0000-4000-8000-000000000003';
  final pdfBytes = utf8.encode('%PDF-1.4 a test document body');

  late Directory root;
  late List<http.BaseRequest> requests;
  late List<(String, String)> opened;
  late List<String> photosEvicted;
  late Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  bool viewerAvailable = true;

  http.StreamedResponse ok(List<int> bytes, {String type = 'application/pdf', String name = 'Site plan (v2).pdf', int? length}) =>
      http.StreamedResponse(
        Stream.value(bytes),
        200,
        headers: {
          'content-type': type,
          'content-length': '${length ?? bytes.length}',
          'content-disposition': "inline; filename=\"x\"; filename*=UTF-8''${Uri.encodeComponent(name)}",
        },
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chat_docs_');
    requests = [];
    opened = [];
    photosEvicted = [];
    viewerAvailable = true;
    ChatDocuments.resetForTest();
    ChatAttachmentCache.resetEvictedForTest();
    ChatDocuments.rootOverride = () async => root;
    respond = (_) async => ok(pdfBytes);
    ChatDocuments.send = (request) {
      requests.add(request);
      return respond(request);
    };
    ChatDocuments.viewer = (path, mime) async {
      opened.add((path, mime));
      return viewerAvailable;
    };
    ChatAttachmentCache.evictPhoto = (id) async => photosEvicted.add(id);
  });

  tearDown(() async {
    ChatDocuments.rootOverride = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  List<String> filesUnder(Directory d) => d.existsSync()
      ? d.listSync(recursive: true).whereType<File>().map((f) => f.path.replaceAll('\\', '/')).toList()
      : [];

  group('first open and repeat open', () {
    test('first open downloads once through GET /d/<id> on the files host, then opens the local copy', () async {
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.opened);
      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.toString(), '${ApiConfig.filesBaseUrl}/d/$pdf');
      final (path, mime) = opened.single;
      expect(mime, 'application/pdf');
      expect(path.replaceAll('\\', '/'), endsWith('/chat_documents/$pdf/Site plan (v2).pdf'),
          reason: 'cached under the message id, keeping the name it was sent with');
      expect(await File(path).readAsBytes(), pdfBytes);
    });

    test('a repeat open is from the phone: no request at all', () async {
      await ChatDocuments.open(pdf);
      requests.clear();
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.opened);
      expect(requests, isEmpty, reason: 'a cache hit must not contact the files endpoint');
      expect(opened, hasLength(2));
      expect(opened[0].$1.replaceAll('\\', '/'), opened[1].$1.replaceAll('\\', '/'));
    });

    test('a cached document opens while offline', () async {
      await ChatDocuments.open(pdf);
      respond = (_) async => throw const SocketException('Failed host lookup');
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.opened);
    });

    test('an uncached document while offline says so and opens nothing', () async {
      respond = (_) async => throw http.ClientException('Failed host lookup: files.help24.co.ke');
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.offline);
      expect(opened, isEmpty);
      expect(filesUnder(root), isEmpty);
    });

    test('a Word document keeps its name and opens as a Word document', () async {
      respond = (_) async => ok([0x50, 0x4b, 3, 4, 9, 9],
          type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', name: 'Quote.docx');
      expect(await ChatDocuments.open(docx), DocumentOpenResult.opened);
      expect(opened.single.$1.replaceAll('\\', '/'), endsWith('/$docx/Quote.docx'));
      expect(opened.single.$2, 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    });

    test('a large document (9 MB) is downloaded whole, once', () async {
      final big = List<int>.filled(9 * 1024 * 1024, 7)..setAll(0, utf8.encode('%PDF'));
      respond = (_) async => http.StreamedResponse(
            Stream.fromIterable([for (var i = 0; i < big.length; i += 65536) big.sublist(i, (i + 65536).clamp(0, big.length))]),
            200,
            headers: {'content-type': 'application/pdf', 'content-length': '${big.length}'},
          );
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.opened);
      expect(await File(opened.single.$1).length(), big.length);
      requests.clear();
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.opened);
      expect(requests, isEmpty);
    });

    test('two documents with the same file name never collide', () async {
      await ChatDocuments.open(pdf);
      respond = (_) async => ok(utf8.encode('%PDF-1.4 a DIFFERENT document'));
      await ChatDocuments.open(pdf2);
      expect(opened[0].$1, isNot(opened[1].$1));
      expect(await File(opened[0].$1).readAsString(), contains('a test document'));
      expect(await File(opened[1].$1).readAsString(), contains('a DIFFERENT document'));
    });

    test('two taps at once download once', () async {
      final gate = Completer<void>();
      respond = (_) async {
        await gate.future;
        return ok(pdfBytes);
      };
      final a = ChatDocuments.open(pdf);
      final b = ChatDocuments.open(pdf);
      gate.complete();
      expect(await Future.wait([a, b]), [DocumentOpenResult.opened, DocumentOpenResult.opened]);
      expect(requests, hasLength(1));
    });

    test('progress shows from the start of a download and clears at the end', () async {
      final seen = <double?>[];
      final listenable = ChatDocuments.progressOf(pdf);
      void listener() => seen.add(listenable.value);
      listenable.addListener(listener);
      await ChatDocuments.open(pdf);
      listenable.removeListener(listener);
      expect(seen.first, -1, reason: 'indeterminate the moment the download starts');
      expect(seen, contains(1.0));
      expect(seen.last, isNull);
    });
  });

  group('nothing incomplete ever becomes a cached document', () {
    test('an interrupted download leaves no file behind, and the next open succeeds', () async {
      respond = (_) async {
        final c = StreamController<List<int>>();
        c.add(pdfBytes.sublist(0, 5));
        c.addError(http.ClientException('Connection closed while receiving data'));
        unawaited(c.close());
        return http.StreamedResponse(c.stream, 200,
            headers: {'content-type': 'application/pdf', 'content-length': '${pdfBytes.length}'});
      };
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.offline);
      expect(filesUnder(root), isEmpty, reason: 'no partial file, no .part leftover');
      expect(await ChatDocuments.cached(pdf), isNull);

      respond = (_) async => ok(pdfBytes);
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.opened);
    });

    test('a body shorter than its Content-Length is refused', () async {
      respond = (_) async => ok(pdfBytes, length: pdfBytes.length + 100);
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.failed);
      expect(filesUnder(root), isEmpty);
    });

    test('a server failure caches nothing', () async {
      respond = (_) async => http.StreamedResponse(Stream.value(utf8.encode('{"code":"UNAVAILABLE"}')), 503);
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.failed);
      expect(filesUnder(root), isEmpty);
    });

    test('an empty or corrupt cached file is discarded and downloaded again', () async {
      Directory('${root.path}/chat_documents/$pdf').createSync(recursive: true);
      File('${root.path}/chat_documents/$pdf/broken.pdf').writeAsBytesSync([]);
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.opened);
      expect(requests, hasLength(1));
      expect(await File(opened.single.$1).readAsBytes(), pdfBytes);
    });

    test('a .part file left by a killed process is swept and never served', () async {
      final dir = Directory('${root.path}/chat_documents/$pdf')..createSync(recursive: true);
      File('${dir.path}/.part-123-456').writeAsBytesSync(pdfBytes);
      expect(await ChatDocuments.cached(pdf), isNull);
      expect(filesUnder(root), isEmpty);
    });

    test('more than 10 MB is refused, declared or not', () async {
      respond = (_) async => ok(pdfBytes, length: ChatAttachments.maxBytes + 1);
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.failed);
      respond = (_) async => http.StreamedResponse(
            Stream.fromIterable([List<int>.filled(6 * 1024 * 1024, 1), List<int>.filled(6 * 1024 * 1024, 1)]),
            200,
            headers: {'content-type': 'application/pdf'},
          );
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.failed);
      expect(filesUnder(root), isEmpty);
    });

    test('anything that is not a document type is refused', () async {
      for (final type in ['text/html', 'image/jpeg', 'application/octet-stream', '']) {
        respond = (_) async => ok(pdfBytes, type: type);
        expect(await ChatDocuments.open(pdf), DocumentOpenResult.failed, reason: type);
      }
      expect(filesUnder(root), isEmpty);
      expect(opened, isEmpty);
    });

    test('an id that is not a message id never touches the file system or the network', () async {
      for (final bad in ['../../etc', 'x', '', '1a1a1a1a-0000-4000-8000-00000000000/']) {
        expect(await ChatDocuments.open(bad), DocumentOpenResult.failed);
      }
      expect(requests, isEmpty);
    });
  });

  group('the endpoint stays the authority', () {
    test('a non-participant (404) gets nothing cached', () async {
      respond = (_) async => http.StreamedResponse(Stream.value(utf8.encode('{"code":"NOT_FOUND"}')), 404);
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.unavailable);
      expect(filesUnder(root), isEmpty);
    });

    test('a message deleted for everyone (410) cannot be newly downloaded — and is not asked for again', () async {
      respond = (_) async => http.StreamedResponse(Stream.value(utf8.encode('{"code":"GONE"}')), 410);
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.gone);
      expect(filesUnder(root), isEmpty);
      requests.clear();
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.gone);
      expect(requests, isEmpty);
    });

    test('no viewer installed is reported, not thrown, so the screen can fall back', () async {
      viewerAvailable = false;
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.noViewer);
    });
  });

  group('delete for everyone removes the local copies', () {
    Message msg(String id, String type, {bool deleted = false}) => Message(
          id: id,
          senderId: 'u',
          text: type == 'file' ? 'x.pdf' : 'Image',
          timestamp: DateTime.utc(2026, 10, 4),
          isMe: false,
          type: type,
          attachmentUrl: 'chat-attachments/c/$id.pdf',
          deletedForEveryone: deleted,
        );

    test('a cached document is removed, cannot be opened again, and other documents stay', () async {
      await ChatDocuments.open(pdf);
      respond = (_) async => ok(utf8.encode('%PDF-1.4 another'));
      await ChatDocuments.open(pdf2);

      ChatAttachmentCache.evictDeleted([msg(pdf, 'file', deleted: true), msg(pdf2, 'file')]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await ChatDocuments.cached(pdf), isNull);
      expect(await ChatDocuments.cached(pdf2), isNotNull, reason: 'unrelated cached attachments remain');
      requests.clear();
      opened.clear();
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.gone);
      expect(requests, isEmpty);
      expect(opened, isEmpty);
    });

    test('a deleted photo is evicted from the photo cache; live messages and text are left alone', () async {
      const photo = '4d4d4d4d-0000-4000-8000-000000000004';
      const other = '5e5e5e5e-0000-4000-8000-000000000005';
      ChatAttachmentCache.evictDeleted([
        msg(photo, 'image', deleted: true),
        msg(other, 'image'),
        msg('6f6f6f6f-0000-4000-8000-000000000006', 'text', deleted: true),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(photosEvicted, [photo]);
      expect(ChatAttachmentCache.isEvicted(photo), isTrue);
      expect(ChatAttachmentCache.isEvicted(other), isFalse);
    });

    test('eviction runs once per message, however often the deletion is seen', () async {
      const photo = '4d4d4d4d-0000-4000-8000-000000000004';
      for (var i = 0; i < 5; i++) {
        ChatAttachmentCache.evictDeleted([msg(photo, 'image', deleted: true)]);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(photosEvicted, [photo]);
    });

    test('a deletion that lands mid-download leaves nothing cached', () async {
      final gate = Completer<void>();
      respond = (_) async {
        final c = StreamController<List<int>>();
        unawaited(gate.future.then((_) {
          c.add(pdfBytes);
          c.close();
        }));
        return http.StreamedResponse(c.stream, 200,
            headers: {'content-type': 'application/pdf', 'content-length': '${pdfBytes.length}'});
      };
      final opening = ChatDocuments.open(pdf);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await ChatAttachmentCache.evict(pdf);
      gate.complete();
      expect(await opening, isNot(DocumentOpenResult.opened));
      expect(await ChatDocuments.cached(pdf), isNull);
      expect(opened, isEmpty);
    });
  });

  group('lifecycle', () {
    test('sign-out clears every cached document', () async {
      await ChatDocuments.open(pdf);
      await ChatDocuments.clearAll();
      expect(filesUnder(root), isEmpty);
      requests.clear();
      expect(await ChatDocuments.open(pdf), DocumentOpenResult.opened);
      expect(requests, hasLength(1), reason: 'after sign-out it is a first open again');
    });

    test('above the size cap the least recently opened documents go first', () async {
      await ChatDocuments.open(pdf);
      await File(opened.last.$1).setLastModified(DateTime(2026, 1, 1));
      respond = (_) async => ok(utf8.encode('%PDF-1.4 newer'));
      await ChatDocuments.open(pdf2);
      await ChatDocuments.prune(maxBytes: 30);
      expect(await ChatDocuments.cached(pdf), isNull);
      expect(await ChatDocuments.cached(pdf2), isNotNull);
    });

    test('file names are made safe and always carry their type', () {
      String name(String raw, [String ext = 'pdf']) =>
          ChatDocuments.fileNameFor("inline; filename*=UTF-8''${Uri.encodeComponent(raw)}", ext);
      expect(name('Mkataba wa kazi — Juni.pdf'), 'Mkataba wa kazi — Juni.pdf');
      expect(name('../../secret.pdf'), 'secret.pdf');
      expect(name('a:b*c?.pdf'), 'a_b_c_.pdf');
      expect(name('.hidden.pdf'), 'hidden.pdf');
      expect(name('report', 'docx'), 'report.docx');
      expect(name(''), 'help24-document.pdf');
      expect(ChatDocuments.fileNameFor(null, 'doc'), 'help24-document.doc');
      expect(name('${'x' * 300}.pdf').length, 120);
    });
  });
}
