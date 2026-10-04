import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/config/api_config.dart';
import 'package:help24/services/api_client.dart';
import 'package:help24/services/chat_attachments.dart';
import 'package:help24/services/chat_service_supabase.dart';
import 'package:http/http.dart' as http;

/// CHAT FILES ARE PRIVATE, AND THE APP ONLY EVER ADDRESSES THEM BY MESSAGE.
///
/// Photos and documents used to be uploaded to a public bucket and their
/// permanent public URL stored in the message — downloadable and listable by
/// anyone. These tests pin the client half of the replacement: what a stored
/// reference may look like, that reads and links go to the files host by
/// message id, and that nothing the app writes or opens is a storage address.
class _Recorder extends http.BaseClient {
  _Recorder(this.seen);
  final List<Uri> seen;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request.url);
    return http.StreamedResponse(Stream.value(const <int>[]), 200);
  }
}

void main() {
  const chat = '0c0c0c0c-0000-4000-8000-000000000001';
  const msg = '1a1a1a1a-0000-4000-8000-000000000001';
  const other = '2b2b2b2b-0000-4000-8000-000000000002';

  group('the stored reference', () {
    test("is accepted only when it names this message's own object", () {
      bool ok(String? ref) => ChatAttachments.isPrivateRefFor(ref, chatId: chat, messageId: msg);
      expect(ok('chat-attachments/$chat/$msg.jpg'), isTrue);
      expect(ok('chat-attachments/$chat/$msg.pdf'), isTrue);
      expect(ok('chat-attachments/$chat/$msg.docx'), isTrue);
      expect(ChatAttachments.isPrivateRefFor('chat-attachments/$chat/$msg.jpg',
          chatId: chat.toUpperCase(), messageId: msg.toUpperCase()), isTrue);

      expect(ok(null), isFalse);
      expect(ok(''), isFalse);
      expect(ok('chat-attachments/$chat/$other.jpg'), isFalse, reason: 'another message');
      expect(ok('chat-attachments/$other/$msg.jpg'), isFalse, reason: 'another chat');
      expect(ok('chat-attachments/$chat/$msg.html'), isFalse, reason: 'not an allowed type');
      expect(ok('post-images/chat_attachments/$chat/$msg.jpg'), isFalse);
      expect(ok('https://x.supabase.co/storage/v1/object/public/post-images/chat_attachments/$chat/$msg.jpg'), isFalse);
      expect(ok('chat-attachments/$chat/$msg.jpg?download'), isFalse);
      expect(ok(' chat-attachments/$chat/$msg.jpg'), isFalse);
    });
  });

  group('reading', () {
    test('a photo is read from the files host by message id, never by storage path', () {
      final url = ChatAttachments.urlFor(msg.toUpperCase());
      expect(url.toString(), '${ApiConfig.filesBaseUrl}/d/$msg');
      expect(url.host, isNot(contains('supabase')));
      expect(ChatAttachments.cacheKeyFor(msg.toUpperCase()), 'chat-attachment:$msg');
    });

    test('the default files host is the Help24 one', () {
      expect(ApiConfig.filesBaseUrl, 'https://files.help24.co.ke');
    });

    test("the image cache's client carries the token to the files host and nowhere else", () async {
      final seen = <Uri>[];
      final client = FilesHostClient(_Recorder(seen));
      await client.get(ChatAttachments.urlFor(msg));
      expect(seen.single.path, '/d/$msg');
      for (final url in [
        'https://taohzhnvaitrpxcyjflq.supabase.co/storage/v1/object/public/post-images/x.jpg',
        'https://api.help24.co.ke/d/$msg',
        'http://files.help24.co.ke/d/$msg',
        'https://files.help24.co.ke.evil.example/d/$msg',
      ]) {
        await expectLater(client.get(Uri.parse(url)), throwsArgumentError, reason: url);
      }
      expect(seen, hasLength(1));
    });
  });

  group('uploading', () {
    late Directory dir;
    late List<http.BaseRequest> sent;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('attach_test_');
      sent = [];
    });
    tearDown(() async {
      ChatAttachmentApi.send = api.sendWithTimeout;
      await dir.delete(recursive: true);
    });

    Future<String> file(String name, List<int> bytes) async {
      final f = File('${dir.path}/$name');
      await f.writeAsBytes(bytes);
      return f.path;
    }

    void respond(int status, Object body) {
      ChatAttachmentApi.send = (request, timeout) async {
        sent.add(request);
        expect(timeout, ChatAttachmentApi.uploadTimeout);
        return http.StreamedResponse(
            Stream.value(utf8.encode(body is String ? body : jsonEncode(body))), status);
      };
    }

    test('PUTs the bytes to /u/<chat>/<message> with the type, and returns the reference', () async {
      respond(201, {'ref': 'chat-attachments/$chat/$msg.jpg', 'stored': true});
      final path = await file('IMG_1.JPEG', [0xff, 0xd8, 0xff, 1, 2, 3]);
      final ref = await ChatAttachmentApi.upload(localPath: path, chatId: chat, messageId: msg);
      expect(ref, 'chat-attachments/$chat/$msg.jpg');
      final request = sent.single as http.Request;
      expect(request.method, 'PUT');
      expect(request.url.toString(), '${ApiConfig.filesBaseUrl}/u/$chat/$msg');
      expect(request.headers['content-type'], 'image/jpeg');
      expect(request.bodyBytes, [0xff, 0xd8, 0xff, 1, 2, 3]);
    });

    test('"already stored" (a retry) returns the same reference', () async {
      respond(200, {'ref': 'chat-attachments/$chat/$msg.pdf', 'stored': false});
      final path = await file('contract.pdf', utf8.encode('%PDF-1.4'));
      expect(await ChatAttachmentApi.upload(localPath: path, chatId: chat, messageId: msg),
          'chat-attachments/$chat/$msg.pdf');
    });

    test('a reference for any other object is refused', () async {
      respond(201, {'ref': 'chat-attachments/$chat/$other.jpg'});
      final path = await file('a.jpg', [0xff, 0xd8, 0xff]);
      await expectLater(
        ChatAttachmentApi.upload(localPath: path, chatId: chat, messageId: msg),
        throwsA(isA<ChatAttachmentException>().having((e) => e.code, 'code', 'BAD_REFERENCE')),
      );
    });

    test('refusals carry their status and code', () async {
      respond(404, {'code': 'NOT_FOUND'});
      final path = await file('a.png', [0x89, 0x50]);
      await expectLater(
        ChatAttachmentApi.upload(localPath: path, chatId: chat, messageId: msg),
        throwsA(isA<ChatAttachmentException>()
            .having((e) => e.statusCode, 'status', 404)
            .having((e) => e.code, 'code', 'NOT_FOUND')),
      );
    });

    test('a type a chat cannot carry, or an oversized file, never leaves the phone', () async {
      respond(201, {});
      final exe = await file('setup.exe', [1, 2, 3]);
      await expectLater(ChatAttachmentApi.upload(localPath: exe, chatId: chat, messageId: msg),
          throwsA(isA<ChatAttachmentException>().having((e) => e.statusCode, 'status', 415)));
      final big = await file('huge.pdf', List<int>.filled(ChatAttachments.maxBytes + 1, 0));
      await expectLater(ChatAttachmentApi.upload(localPath: big, chatId: chat, messageId: msg),
          throwsA(isA<ChatAttachmentException>().having((e) => e.statusCode, 'status', 413)));
      expect(sent, isEmpty);
    });
  });

  group('opening a document in the browser', () {
    tearDown(() => ChatAttachmentApi.send = api.sendWithTimeout);

    void respond(int status, Object body) {
      ChatAttachmentApi.send = (request, timeout) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), '${ApiConfig.filesBaseUrl}/links/$msg');
        return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status);
      };
    }

    test('asks for a one-time link for this message and opens only a files-host URL', () async {
      respond(200, {'url': '${ApiConfig.filesBaseUrl}/d/$msg?t=abc.def', 'expires_in': 120});
      final link = await ChatAttachmentApi.browserLink(msg);
      expect(link.host, Uri.parse(ApiConfig.filesBaseUrl).host);
      expect(link.path, '/d/$msg');
    });

    test('a link anywhere else is never opened', () async {
      for (final url in [
        'https://taohzhnvaitrpxcyjflq.supabase.co/storage/v1/object/sign/x?token=y',
        '${ApiConfig.filesBaseUrl}/d/$other?t=abc',
        'https://evil.example/d/$msg?t=abc',
        'javascript:alert(1)',
      ]) {
        respond(200, {'url': url});
        await expectLater(ChatAttachmentApi.browserLink(msg),
            throwsA(isA<ChatAttachmentException>().having((e) => e.code, 'code', 'BAD_LINK')),
            reason: url);
      }
    });

    test('a deleted message says so', () async {
      respond(410, {'code': 'GONE'});
      await expectLater(ChatAttachmentApi.browserLink(msg),
          throwsA(isA<ChatAttachmentException>().having((e) => e.isGone, 'isGone', isTrue)));
    });
  });

  group('a photo deleted for everyone', () {
    testWidgets('leaves the decoded-image cache under the key every chat photo is drawn with',
        (tester) async {
      // What the bubbles and the viewer build: url + message-keyed cacheKey
      // (their cacheManager is not part of provider equality).
      final drawn = CachedNetworkImageProvider(
        ChatAttachments.urlFor(msg).toString(),
        cacheKey: ChatAttachments.cacheKeyFor(msg),
      );
      final unrelated = CachedNetworkImageProvider(
        ChatAttachments.urlFor(other).toString(),
        cacheKey: ChatAttachments.cacheKeyFor(other),
      );
      final image = await tester.runAsync(() => createTestImage(width: 4, height: 4));
      for (final p in [drawn, unrelated]) {
        imageCache.putIfAbsent(
            p, () => OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image!.clone()))));
      }
      expect(imageCache.containsKey(drawn), isTrue);

      // The library's own probe is URL-only and misses it — the reason for
      // evictDecodedPhoto.
      expect(await CachedNetworkImageProvider(ChatAttachments.urlFor(msg).toString()).evict(), isFalse);
      expect(imageCache.containsKey(drawn), isTrue);

      expect(await ChatAttachmentCache.evictDecodedPhoto(msg.toUpperCase()), isTrue);
      expect(imageCache.containsKey(drawn), isFalse);
      expect(imageCache.containsKey(unrelated), isTrue, reason: 'another message is untouched');
      expect(await ChatAttachmentCache.evictDecodedPhoto(msg), isFalse, reason: 'idempotent');
      imageCache.clear();
      image!.dispose();
    });
  });

  group('writing the message', () {
    test('a public storage URL is refused before anything is written', () async {
      for (final ref in [
        'https://taohzhnvaitrpxcyjflq.supabase.co/storage/v1/object/public/post-images/chat_attachments/$chat/$msg.jpg',
        'chat-attachments/$chat/$other.jpg',
      ]) {
        await expectLater(
          ChatServiceSupabase.sendAttachmentMessage(
            chatIdParam: chat,
            senderId: 'uid',
            type: 'image',
            attachmentUrl: ref,
            clientMessageId: msg,
          ),
          throwsA(isA<ChatServiceException>()),
          reason: ref,
        );
      }
      await expectLater(
        ChatServiceSupabase.sendAttachmentMessage(
          chatIdParam: chat,
          senderId: 'uid',
          type: 'file',
          attachmentUrl: 'chat-attachments/$chat/$msg.pdf',
        ),
        throwsA(isA<ChatServiceException>()),
        reason: 'no message id, so no object can be its own',
      );
    });
  });
}
