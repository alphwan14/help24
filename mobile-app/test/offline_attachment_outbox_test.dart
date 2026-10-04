import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';
import 'package:help24/providers/connectivity_provider.dart';
import 'package:help24/services/cache_service.dart';
import 'package:help24/services/chat_service_supabase.dart';
import 'package:help24/services/outbox_delivery.dart';
import 'package:help24/services/outbox_store.dart';
import 'package:help24/services/chat_attachments.dart';
import 'package:http/http.dart' show ClientException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sdk
    show PostgrestException;

/// PHOTOS, DOCUMENTS AND PLACES CAN BE SENT OFFLINE.
///
/// THE BUG THIS LOCKS DOWN
/// -----------------------
/// The outbox could only send text. A photo, a contract or a pinned place was
/// uploaded or inserted the moment it was picked, and offline that failed: a
/// snackbar, and the attachment was gone — no bubble, no queue, nothing on
/// disk to retry from. The picked file lived in the picker's cache directory,
/// referenced only from memory.
///
/// These tests pin the replacement: every message type enters the same queue,
/// survives a restart, is delivered by one function on reconnect, and — the
/// rule that makes retrying safe at all — is never stored on the server twice.
void main() {
  const uid = 'uid-sender';
  // A real uuid: a stored file's reference is chat-attachments/<chat>/<id>.<ext>.
  const chat = '0c0c0c0c-0000-4000-8000-000000000001';
  late Directory root;
  late _FakeTransport transport;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NetworkHealth.resetForTest();
    OutboxStore.instance.resetForSignOut();
    root = await Directory.systemTemp.createTemp('outbox_test_');
    OutboxFiles.rootOverride = () async => root;
    transport = _FakeTransport();
    OutboxDelivery.transport = transport;
  });

  tearDown(() async {
    OutboxStore.instance.resetForSignOut();
    NetworkHealth.resetForTest();
    OutboxDelivery.transport = const SupabaseOutboxTransport();
    // Let the sign-out purge (fire-and-forget) finish before the override goes.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    OutboxFiles.rootOverride = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// A file standing in for what image_picker / file_picker hand back.
  Future<File> pickedFile(String name, {int bytes = 2048}) async {
    final f = File('${root.path}/picker_cache_$name');
    await f.writeAsBytes(List<int>.filled(bytes, 7));
    return f;
  }

  Future<Message> queuedPhoto({String caption = ''}) async {
    final id = OutboxIds.create();
    final src = await pickedFile('IMG_0001.jpg');
    final local = await OutboxFiles.adopt(
      sourcePath: src.path,
      uid: uid,
      messageId: id,
      name: 'IMG_0001.jpg',
    );
    return Message(
      id: id,
      senderId: uid,
      text: ChatServiceSupabase.attachmentContent('image', caption),
      timestamp: DateTime.utc(2026, 10, 3, 9),
      isMe: true,
      type: 'image',
      status: OutboxStatus.queued,
      localPath: local,
    );
  }

  Future<Message> queuedDocument() async {
    final id = OutboxIds.create();
    final src = await pickedFile('contract.pdf', bytes: 40000);
    final local = await OutboxFiles.adopt(
      sourcePath: src.path,
      uid: uid,
      messageId: id,
      name: 'contract.pdf',
    );
    return Message(
      id: id,
      senderId: uid,
      text: ChatServiceSupabase.attachmentContent('file', 'contract.pdf'),
      timestamp: DateTime.utc(2026, 10, 3, 9, 1),
      isMe: true,
      type: 'file',
      status: OutboxStatus.queued,
      localPath: local,
    );
  }

  Message queuedText(String text, {DateTime? at}) => Message(
        id: OutboxIds.create(),
        senderId: uid,
        text: text,
        timestamp: at ?? DateTime.utc(2026, 10, 3, 9, 2),
        isMe: true,
        status: OutboxStatus.queued,
      );

  Message queuedPlace() => Message(
        id: OutboxIds.create(),
        senderId: uid,
        text: 'Black gate next to the kiosk',
        timestamp: DateTime.utc(2026, 10, 3, 9, 3),
        isMe: true,
        type: 'location',
        latitude: -4.0435,
        longitude: 39.6682,
        status: OutboxStatus.queued,
      );

  // ───────────────────────────────────────────────────────────────────────────
  group('identity — one id from compose to server row', () {
    test('a new outbox id carries the uuid the server row will use', () {
      final id = OutboxIds.create();
      expect(OutboxIds.isPending(id), isTrue);
      final serverId = OutboxIds.serverIdOf(id);
      expect(serverId, isNotNull);
      expect(id, 'pending_$serverId');
    });

    test('two messages never share an id', () {
      final ids = {for (var i = 0; i < 200; i++) OutboxIds.create()};
      expect(ids.length, 200);
    });

    test('a message queued by an older build has no server id', () {
      // pending_<millis> — no row id was ever promised for it.
      expect(OutboxIds.serverIdOf('pending_1759480000000'), isNull);
      expect(OutboxIds.serverIdOf('8f0e…not-pending'), isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('delivery — every message type, one function', () {
    test('TEXT is inserted under its own id', () async {
      final m = queuedText('Can you come tomorrow?');
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      expect(transport.calls, ['text:${OutboxIds.serverIdOf(m.id)}']);
      expect(transport.rows.values.single.text, 'Can you come tomorrow?');
    });

    test('IMAGE: upload named by the message id, then the row, then the copy is removed',
        () async {
      final m = await queuedPhoto(caption: 'Leak under the sink');
      final serverId = OutboxIds.serverIdOf(m.id)!;
      Message? uploaded;
      final confirmed = await OutboxDelivery.deliver(
        senderId: uid,
        chatId: chat,
        message: m,
        onUploaded: (u) => uploaded = u,
      );
      expect(transport.calls, ['upload:$serverId', 'attachment:image:$serverId']);
      expect(uploaded?.attachmentUrl, 'chat-attachments/$chat/$serverId.jpg',
          reason: 'the private reference is handed back for persisting before the insert');
      expect(confirmed.attachmentUrl, uploaded!.attachmentUrl);
      expect(transport.rows[serverId]!.text, 'Leak under the sink');
      expect(transport.remembered, [serverId],
          reason: 'the sender should not re-download their own photo');
      expect(await File(m.localPath!).exists(), isFalse,
          reason: 'the queued copy is deleted once delivered');
    });

    test('a captionless IMAGE is written as "Image", like an online send', () async {
      final m = await queuedPhoto();
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      expect(transport.rows.values.single.text, 'Image');
    });

    test('DOCUMENT keeps its file name as the message text', () async {
      final m = await queuedDocument();
      final serverId = OutboxIds.serverIdOf(m.id)!;
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      expect(transport.calls, ['upload:$serverId', 'attachment:file:$serverId']);
      expect(transport.rows[serverId]!.text, 'contract.pdf');
      expect(transport.uploadedNames.single, endsWith('.pdf'),
          reason: 'the extension decides the stored content type');
      expect(transport.remembered, isEmpty,
          reason: 'only photos seed the image cache');
    });

    test('LOCATION carries its coordinates and label', () async {
      final m = queuedPlace();
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      final row = transport.rows.values.single;
      expect(row.type, 'location');
      expect(row.latitude, -4.0435);
      expect(row.longitude, 39.6682);
      expect(row.text, 'Black gate next to the kiosk');
    });

    test('an unlabelled LOCATION is sent without a label', () async {
      final m = queuedPlace().copyWith(text: 'Location');
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      expect(transport.lastLabel, isNull);
    });

    test('a LOCATION REQUEST is queueable like text', () async {
      final m = Message(
        id: OutboxIds.create(),
        senderId: uid,
        text: 'Location requested',
        timestamp: DateTime.utc(2026, 10, 3),
        isMe: true,
        type: 'location_request',
      );
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      expect(transport.rows.values.single.type, 'location_request');
    });

    test('a queued attachment whose file is gone fails permanently', () async {
      final m = await queuedPhoto();
      await File(m.localPath!).delete();
      await expectLater(
        OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m),
        throwsA(isA<OutboxPermanentFailure>()),
      );
      expect(transport.calls, isEmpty);
    });

    test('a legacy queued message is sent without an idempotency key', () async {
      final m = queuedText('old build').copyWith(id: 'pending_1759480000000');
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      expect(transport.calls, ['text:null']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('PRIVATE STORAGE — no chat file is ever sent at a public address', () {
    test('a photo an older build stored PUBLICLY is re-uploaded privately first', () async {
      // v1.0.1 persisted the public URL on the queued message the moment its
      // upload finished. If that message is still queued when 1.0.2 starts,
      // the public address must not be written into the conversation.
      final m = await queuedPhoto();
      final serverId = OutboxIds.serverIdOf(m.id)!;
      final stale = m.copyWith(
          attachmentUrl: 'https://taohzhnvaitrpxcyjflq.supabase.co/storage/v1/object/public/'
              'post-images/chat_attachments/$chat/$serverId.jpg');
      final confirmed = await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: stale);
      expect(transport.calls, ['upload:$serverId', 'attachment:image:$serverId']);
      expect(confirmed.attachmentUrl, 'chat-attachments/$chat/$serverId.jpg');
    });

    test("another message's private reference is never reused", () async {
      final m = await queuedPhoto();
      final serverId = OutboxIds.serverIdOf(m.id)!;
      final borrowed = m.copyWith(
          attachmentUrl: 'chat-attachments/$chat/0d0d0d0d-0000-4000-8000-000000000002.jpg');
      final confirmed =
          await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: borrowed);
      expect(transport.calls.first, 'upload:$serverId');
      expect(confirmed.attachmentUrl, 'chat-attachments/$chat/$serverId.jpg');
    });

    test('an attachment queued without a message id cannot be stored — failed, not sent',
        () async {
      final m = (await queuedPhoto()).copyWith(id: 'pending_1759480000000');
      await expectLater(
        OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m),
        throwsA(isA<OutboxPermanentFailure>()),
      );
      expect(transport.calls, isEmpty);
    });

    test('a stored private reference skips the upload on retry', () async {
      final m = await queuedPhoto();
      final serverId = OutboxIds.serverIdOf(m.id)!;
      final uploaded = m.copyWith(attachmentUrl: 'chat-attachments/$chat/$serverId.jpg');
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: uploaded);
      expect(transport.calls, ['attachment:image:$serverId']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('DUPLICATE-SEND PROTECTION', () {
    test('a retry after the upload succeeded does not upload again', () async {
      final m = await queuedPhoto();
      final serverId = OutboxIds.serverIdOf(m.id)!;
      transport.attachmentError = ClientException('Connection closed while receiving data');
      Message? afterUpload;
      await expectLater(
        OutboxDelivery.deliver(
          senderId: uid,
          chatId: chat,
          message: m,
          onUploaded: (u) => afterUpload = u,
        ),
        throwsA(isA<ClientException>()),
      );
      expect(await File(m.localPath!).exists(), isTrue,
          reason: 'nothing is deleted until the message exists');

      // The caller persisted `afterUpload`; the retry sends that copy.
      transport.calls.clear();
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: afterUpload!);
      expect(transport.calls, ['attachment:image:$serverId']);
      expect(transport.rows, hasLength(1));
    });

    test('a retry after the insert committed but its response was lost adopts the row',
        () async {
      final m = queuedText('Can you come tomorrow?');
      transport.loseInsertResponse = true;
      await expectLater(
        OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m),
        throwsA(isA<ClientException>()),
      );
      expect(transport.rows, hasLength(1), reason: 'the server did store it');

      final confirmed =
          await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      expect(transport.rows, hasLength(1), reason: 'and still only once');
      expect(confirmed.id, OutboxIds.serverIdOf(m.id));
    });

    test('a killed process re-uploading the same file reuses the stored object', () async {
      final m = await queuedPhoto();
      transport.attachmentError = ClientException('Software caused connection abort');
      await expectLater(
        OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m),
        throwsA(isA<ClientException>()),
      );
      // The URL never reached disk: the retry starts from the original message.
      await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
      expect(transport.storedObjects, hasLength(1));
      expect(transport.rows, hasLength(1));
    });

    test('the server row adopted on a replay must be the same chat and sender', () {
      final insert = {'chat_id': 'c1', 'sender_id': 'u1', 'content': 'hi'};
      expect(
        ChatServiceSupabase.isReplayOf(
            {'id': 'x', 'chat_id': 'c1', 'sender_id': 'u1'}, insert),
        isTrue,
      );
      expect(ChatServiceSupabase.isReplayOf(null, insert), isFalse);
      expect(
        ChatServiceSupabase.isReplayOf(
            {'id': 'x', 'chat_id': 'c2', 'sender_id': 'u1'}, insert),
        isFalse,
        reason: 'a colliding id in someone else\'s chat is a conflict, not ours',
      );
      expect(
        ChatServiceSupabase.isReplayOf(
            {'id': 'x', 'chat_id': 'c1', 'sender_id': 'u2'}, insert),
        isFalse,
      );
    });


    test('the screen and the store sending at once deliver a photo exactly once',
        () async {
      final m = await queuedPhoto();
      OutboxStore.instance.debugSeed(uid, {
        chat: [m],
      });
      transport.delay = const Duration(milliseconds: 30);
      // ChatScreen's sender, reduced to its claim discipline.
      Future<void> screenSend() async {
        if (!OutboxStore.instance.claimSend(m.id)) return;
        try {
          await OutboxDelivery.deliver(senderId: uid, chatId: chat, message: m);
        } finally {
          OutboxStore.instance.releaseSend(m.id);
        }
      }

      await Future.wait([OutboxStore.instance.drain(), screenSend()]);
      expect(transport.calls.where((c) => c.startsWith('upload')), hasLength(1));
      expect(transport.rows, hasLength(1));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('status after a failed attempt', () {
    test('offline → queued (clock), never failed', () {
      NetworkHealth.publish(offline: true);
      final status = OutboxStore.instance.statusAfterFailure(
          'pending_x', ClientException('Failed host lookup: api.help24.co.ke'));
      expect(status, OutboxStatus.queued);
    });

    test('a transient failure while online is retried, then marked failed', () {
      final error = ClientException('Connection reset by peer');
      final statuses = [
        for (var i = 0; i <= OutboxStore.transientRetryDelays.length; i++)
          OutboxStore.instance.statusAfterFailure('pending_x', error),
      ];
      expect(statuses.take(OutboxStore.transientRetryDelays.length),
          everyElement(OutboxStatus.queued));
      expect(statuses.last, OutboxStatus.failed);
    });

    test('a manual retry earns a fresh transient budget', () {
      final error = TimeoutException('upload');
      for (var i = 0; i < OutboxStore.transientRetryDelays.length; i++) {
        OutboxStore.instance.statusAfterFailure('pending_x', error);
      }
      OutboxStore.instance.clearFailures('pending_x');
      expect(OutboxStore.instance.statusAfterFailure('pending_x', error),
          OutboxStatus.queued);
    });

    test('a server refusal is failed at once — a timer cannot fix it', () {
      const refused = sdk.PostgrestException(
          message: 'new row violates row-level security policy', code: '42501');
      expect(OutboxStore.instance.statusAfterFailure('pending_x', refused),
          OutboxStatus.failed);
    });

    test('a missing queued file is failed at once', () {
      expect(
        OutboxStore.instance.statusAfterFailure(
            'pending_x', const OutboxPermanentFailure('attachment file missing')),
        OutboxStatus.failed,
      );
    });

    test('the files endpoint: unavailable is retried, a refusal is failed at once', () {
      expect(
        OutboxStore.instance.statusAfterFailure(
            'pending_a', const ChatAttachmentException(503, 'UNAVAILABLE')),
        OutboxStatus.queued,
      );
      for (final refusal in const [
        ChatAttachmentException(404, 'NOT_FOUND'),
        ChatAttachmentException(413, 'TOO_LARGE'),
        ChatAttachmentException(415, 'CONTENT_MISMATCH'),
      ]) {
        expect(OutboxStore.instance.statusAfterFailure('pending_b', refusal),
            OutboxStatus.failed, reason: refusal.toString());
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('persistence — a queued attachment survives a restart', () {
    test('the outbox round-trips type, file, url and coordinates', () async {
      final photo = await queuedPhoto(caption: 'Meter reading');
      final doc = await queuedDocument();
      final uploadedDoc = doc.copyWith(
          attachmentUrl: 'chat-attachments/$chat/${OutboxIds.serverIdOf(doc.id)}.pdf');
      final place = queuedPlace();
      await CacheService.saveOutbox(uid, chat, [photo, uploadedDoc, place]);

      final loaded = await CacheService.loadOutbox(chat, uid);
      expect(loaded.map((m) => m.type), ['image', 'file', 'location']);
      expect(loaded[0].localPath, photo.localPath);
      expect(loaded[0].text, 'Meter reading');
      expect(loaded[0].id, photo.id, reason: 'the id is the idempotency key');
      expect(loaded[1].attachmentUrl, uploadedDoc.attachmentUrl,
          reason: 'an upload already done is not repeated after restart');
      expect(loaded[2].latitude, -4.0435);
      expect(loaded[2].longitude, 39.6682);
    });

    test('a message composed on the phone keeps its time across a restart', () async {
      // Found on the S20+ (EAT, UTC+3): composed at 1:09 PM, re-read from the
      // outbox as 4:09 PM — a LOCAL DateTime was written without a zone and
      // read back as UTC. Every queued message moved by the device offset.
      final composedAt = DateTime(2026, 10, 3, 13, 9, 30); // local, as DateTime.now()
      final m = queuedText('what time is it?', at: composedAt);
      await CacheService.saveOutbox(uid, chat, [m]);
      final loaded = (await CacheService.loadOutbox(chat, uid)).single;
      expect(loaded.timestamp.isAtSameMomentAs(composedAt), isTrue,
          reason: 'loaded ${loaded.timestamp.toUtc()} vs composed ${composedAt.toUtc()}');
    });

    test('a message killed mid-send comes back queued, not "sending"', () async {
      final m = queuedText('hello').copyWith(status: OutboxStatus.sending);
      await CacheService.saveOutbox(uid, chat, [m]);
      final loaded = await CacheService.loadOutbox(chat, uid);
      expect(loaded.single.status, OutboxStatus.queued);
    });

    test('a server row never carries a local path into the thread cache', () {
      final row = Message.fromJson({
        'id': 'r1',
        'sender_id': uid,
        'content': 'Image',
        'type': 'image',
        'attachment_url': 'https://cdn.test/a.jpg',
        'created_at': '2026-10-03T09:00:00Z',
      }, uid);
      expect(row.localPath, isNull);
      expect(row.toCacheMap().containsKey('local_path'), isFalse);
    });

    test('the store hydrates queued attachments from disk on start', () async {
      final photo = await queuedPhoto();
      await CacheService.saveOutbox(uid, chat, [photo]);
      NetworkHealth.publish(offline: true); // nothing may be sent yet
      await OutboxStore.instance.start(uid);
      final queue = OutboxStore.instance.queueFor(chat);
      expect(queue.single.id, photo.id);
      expect(queue.single.localPath, photo.localPath);
      expect(await File(photo.localPath!).exists(), isTrue,
          reason: 'the startup sweep must keep a copy the queue still needs');
      expect(transport.calls, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('automatic sending on reconnect', () {
    test('queued text, photo, document and place all go out on the reconnect edge',
        () async {
      final photo = await queuedPhoto();
      final doc = await queuedDocument();
      final text = queuedText('Can you come tomorrow?');
      final place = queuedPlace();
      await CacheService.saveOutbox(uid, chat, [photo, doc, text, place]);

      NetworkHealth.publish(offline: true);
      await OutboxStore.instance.start(uid);
      expect(transport.calls, isEmpty, reason: 'offline: nothing is attempted');

      NetworkHealth.publish(offline: false); // the reconnect edge
      await _settle();

      expect(transport.rows, hasLength(4));
      expect(transport.rows.values.map((m) => m.type).toList(),
          ['image', 'file', 'text', 'location'],
          reason: 'drained oldest first, in the order composed');
      expect(OutboxStore.instance.queueFor(chat), isEmpty);
      expect(await CacheService.loadOutbox(chat, uid), isEmpty,
          reason: 'delivered messages leave the disk queue too');
    });

    test('the thread on screen is left to ChatScreen', () async {
      final text = queuedText('mine to send');
      OutboxStore.instance.debugSeed(uid, {chat: [text]});
      OutboxStore.instance.setActiveChat(chat);
      await OutboxStore.instance.drain();
      expect(transport.calls, isEmpty);
    });

    test('nothing is attempted while offline', () async {
      OutboxStore.instance.debugSeed(uid, {chat: [queuedText('wait')]});
      NetworkHealth.publish(offline: true);
      await OutboxStore.instance.drain();
      expect(transport.calls, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('NETWORK INTERRUPTION DURING UPLOAD', () {
    test('the photo stays queued, then is delivered once on reconnect', () async {
      final photo = await queuedPhoto();
      await CacheService.saveOutbox(uid, chat, [photo]);
      NetworkHealth.publish(offline: true);
      await OutboxStore.instance.start(uid);

      // The connection returns and the upload starts — then the radio dies
      // mid-upload (airplane mode on the device).
      transport.onUpload = () => NetworkHealth.publish(offline: true);
      transport.uploadError = ClientException('Connection closed while sending data');
      NetworkHealth.publish(offline: false);
      await _settle();
      expect(transport.calls, ['upload:${OutboxIds.serverIdOf(photo.id)}'],
          reason: 'the upload really was in progress');

      final stuck = OutboxStore.instance.queueFor(chat).single;
      expect(stuck.status, OutboxStatus.queued,
          reason: 'waiting for a network is not a failure');
      expect(await File(stuck.localPath!).exists(), isTrue,
          reason: 'the attachment must not silently disappear');
      expect(transport.rows, isEmpty);

      transport.onUpload = null;
      NetworkHealth.publish(offline: false);
      await _settle();
      expect(transport.rows, hasLength(1));
      expect(OutboxStore.instance.queueFor(chat), isEmpty);
    });

    test('a refused send stays in the queue as failed — never dropped', () async {
      final photo = await queuedPhoto();
      OutboxStore.instance.debugSeed(uid, {
        chat: [photo],
      });
      transport.attachmentError = const sdk.PostgrestException(
          message: 'new row violates row-level security policy', code: '42501');
      await OutboxStore.instance.drain();
      final kept = OutboxStore.instance.queueFor(chat).single;
      expect(kept.status, OutboxStatus.failed);
      expect(kept.attachmentUrl, isNotNull,
          reason: 'the upload is remembered so Retry only writes the row');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('the queued file copy', () {
    test('is made in app storage, keeping the extension', () async {
      final src = await pickedFile('scan.PDF');
      final path = await OutboxFiles.adopt(
          sourcePath: src.path, uid: uid, messageId: 'pending_abc', name: 'scan.PDF');
      expect(path, startsWith(root.path));
      expect(path, endsWith('pending_abc.pdf'));
      expect(await File(path).length(), await src.length());
      // The picker's cache can be cleared without touching the queue.
      await src.delete();
      expect(await File(path).exists(), isTrue);
    });

    test('is removed at sign-out with the queue that referenced it', () async {
      final photo = await queuedPhoto();
      OutboxStore.instance.publish(uid, chat, [photo]);
      OutboxStore.instance.resetForSignOut();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await File(photo.localPath!).exists(), isFalse);
    });

    test('orphans are swept; referenced and fresh copies are kept', () async {
      final keep = await queuedPhoto();
      final orphan = await queuedPhoto();
      final fresh = await queuedPhoto();
      final old = DateTime.now().subtract(const Duration(hours: 2));
      await File(keep.localPath!).setLastModified(old);
      await File(orphan.localPath!).setLastModified(old);

      final removed = await OutboxFiles.sweep(uid: uid, keep: {keep.localPath!});
      expect(removed, 1);
      expect(await File(keep.localPath!).exists(), isTrue);
      expect(await File(orphan.localPath!).exists(), isFalse);
      expect(await File(fresh.localPath!).exists(), isTrue,
          reason: 'a copy made moments ago may belong to a message being queued');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('the thread shows every message exactly once', () {
    Message delivered(String id, String text, DateTime at, {String type = 'text'}) =>
        Message(id: id, senderId: uid, text: text, timestamp: at, isMe: true, type: type);

    test('two captionless photos are BOTH shown while queued', () {
      // The old "same text within 15s" match hid the second: both read "Image".
      final t = DateTime.utc(2026, 10, 3, 9);
      final first = delivered('row-1', 'Image', t, type: 'image');
      final second = Message(
        id: OutboxIds.create(),
        senderId: uid,
        text: 'Image',
        timestamp: t.add(const Duration(seconds: 2)),
        isMe: true,
        type: 'image',
        status: OutboxStatus.queued,
      );
      final thread = mergeOutboxIntoThread([first], [second]);
      expect(thread, hasLength(2));
    });

    test('a queued message whose row has arrived is shown once, as the row', () {
      final q = queuedText('hello');
      final row = delivered(OutboxIds.serverIdOf(q.id)!, 'hello', q.timestamp);
      final thread = mergeOutboxIntoThread([row], [q]);
      expect(thread.single.id, row.id);
    });

    test('identical text sent twice on purpose is shown twice', () {
      final t = DateTime.utc(2026, 10, 3, 9);
      final row = delivered('row-1', 'ok', t);
      final q = queuedText('ok', at: t.add(const Duration(seconds: 3)));
      expect(mergeOutboxIntoThread([row], [q]), hasLength(2));
    });

    test('legacy queued text still uses the old match', () {
      final t = DateTime.utc(2026, 10, 3, 9);
      final row = delivered('row-1', 'ok', t);
      final legacy = queuedText('ok', at: t).copyWith(id: 'pending_1759480000000');
      expect(mergeOutboxIntoThread([row], [legacy]), hasLength(1));
    });

    test('the merged thread is in time order', () {
      final t = DateTime.utc(2026, 10, 3, 9);
      final q = queuedText('later', at: t.add(const Duration(minutes: 1)));
      final row = delivered('row-1', 'earlier', t);
      expect(mergeOutboxIntoThread([row], [q]).map((m) => m.text), ['earlier', 'later']);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  group('the Messages tab preview of a queued message', () {
    test('matches what the server will write once it is delivered', () {
      expect(ChatServiceSupabase.previewFor(type: 'image', content: 'Image'), 'Image');
      expect(ChatServiceSupabase.previewFor(type: 'file', content: 'contract.pdf'),
          'contract.pdf');
      expect(ChatServiceSupabase.previewFor(type: 'location', content: 'Black gate'),
          '📍 Black gate');
      expect(ChatServiceSupabase.previewFor(type: 'location', content: 'Location'),
          'Location');
      expect(
          ChatServiceSupabase.previewFor(
              type: 'location_request', content: 'Location requested'),
          '📍 Location requested');
      expect(ChatServiceSupabase.previewFor(type: 'text', content: 'hi'), 'hi');
    });
  });
}

/// Let the reconnect listener and the drain it starts run to completion.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The server, as the outbox sees it. Behaves like the real one where it
/// matters to these tests: an object name or row id that already exists is
/// answered with what is already there (the files endpoint's "already
/// stored", Postgres' 23505 — adopted by ChatAttachmentApi and
/// ChatServiceSupabase respectively).
class _FakeTransport extends OutboxTransport {
  final List<String> calls = [];
  final Map<String, Message> rows = {};
  final Set<String> storedObjects = {};
  final List<String> uploadedNames = [];
  final List<String> remembered = [];
  String? lastLabel;

  /// One-shot failures.
  Object? uploadError;
  Object? attachmentError;
  bool loseInsertResponse = false;

  void Function()? onUpload;
  Duration delay = Duration.zero;

  Future<void> _pause() async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
  }

  Message _store(String? id, String type, String text,
      {String? url, double? lat, double? lng}) {
    final key = id ?? 'auto-${rows.length}';
    final row = rows.putIfAbsent(
      key,
      () => Message(
        id: key,
        senderId: 'uid-sender',
        text: text,
        timestamp: DateTime.utc(2026, 10, 3),
        isMe: true,
        type: type,
        attachmentUrl: url,
        latitude: lat,
        longitude: lng,
      ),
    );
    if (loseInsertResponse) {
      loseInsertResponse = false;
      throw ClientException('Connection closed before full header was received');
    }
    return row;
  }

  @override
  Future<void> ensureSession() async {}

  @override
  Future<String> upload({
    required String localPath,
    required String chatId,
    required String messageId,
  }) async {
    calls.add('upload:$messageId');
    onUpload?.call();
    await _pause();
    final e = uploadError;
    if (e != null) {
      uploadError = null;
      throw e;
    }
    final ext = OutboxFiles.extensionOf(localPath);
    final name = '$messageId.${ext == 'jpeg' ? 'jpg' : ext}';
    uploadedNames.add(name);
    storedObjects.add(name); // a second upload of the same name is a no-op
    return 'chat-attachments/$chatId/$name';
  }

  @override
  Future<Message> sendText({
    required String chatId,
    required String senderId,
    required Message message,
    String? clientMessageId,
  }) async {
    calls.add('text:$clientMessageId');
    await _pause();
    return _store(clientMessageId, 'text', message.text);
  }

  @override
  Future<Message> sendAttachment({
    required String chatId,
    required String senderId,
    required String type,
    required String attachmentUrl,
    required String caption,
    String? clientMessageId,
  }) async {
    calls.add('attachment:$type:$clientMessageId');
    await _pause();
    final e = attachmentError;
    if (e != null) {
      attachmentError = null;
      throw e;
    }
    return _store(clientMessageId, type,
        ChatServiceSupabase.attachmentContent(type, caption),
        url: attachmentUrl);
  }

  @override
  Future<Message> sendLocation({
    required String chatId,
    required String senderId,
    required double latitude,
    required double longitude,
    String? label,
    String? clientMessageId,
  }) async {
    calls.add('location:$clientMessageId');
    lastLabel = label;
    await _pause();
    return _store(clientMessageId, 'location', label ?? 'Location',
        lat: latitude, lng: longitude);
  }

  @override
  Future<Message> sendLocationRequest({
    required String chatId,
    required String senderId,
    String? clientMessageId,
  }) async {
    calls.add('location_request:$clientMessageId');
    await _pause();
    return _store(clientMessageId, 'location_request', 'Location requested');
  }

  @override
  Future<void> rememberImage({required String messageId, required String localPath}) async {
    remembered.add(messageId);
  }
}
