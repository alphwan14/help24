import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/support_thread.dart';
import 'package:help24/providers/auth_provider.dart';
import 'package:help24/providers/connectivity_provider.dart';
import 'package:help24/screens/support_thread_screen.dart';
import 'package:help24/services/support_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

/// MESSAGE HELP24: THE MEMBER'S CONVERSATION WITH HELP24.
///
/// A member writes from Profile → Message Help24; staff answer from the
/// dashboard Inbox and the answer arrives here with a notification. These
/// tests hold the parts that would hurt if they slipped: what is shown as
/// Help24's (never a staff name), that a message appears the moment it is
/// written, that a failed send is kept and can be sent again without being
/// stored twice, and that photos go up before the message that names them.

class _FakeAuth extends AuthProvider {
  _FakeAuth(this._uid);
  final String _uid;
  @override
  String? get currentUserId => _uid;
}

class _FakeApi implements SupportApi {
  _FakeApi(this.thread0);
  SupportThread thread0;
  bool failSends = false;
  final List<String> sentClientIds = [];
  final List<List<String>> sentPhotoPaths = [];
  final List<String> sentBodies = [];
  final List<int> uploadedCounts = [];
  final List<String> reads = [];

  @override
  Future<SupportThread> thread(String userId) async => thread0;

  @override
  Future<List<String>> uploadPhotos({required String userId, required List<SupportPhoto> photos}) async {
    if (photos.isEmpty) return const [];
    uploadedCounts.add(photos.length);
    return [for (var i = 0; i < photos.length; i++) 'members/$userId/photo-$i.png'];
  }

  @override
  Future<SupportMessage> send({
    required String userId,
    required String body,
    required String clientId,
    List<String> photoPaths = const [],
  }) async {
    sentClientIds.add(clientId);
    sentBodies.add(body);
    sentPhotoPaths.add(photoPaths);
    if (failSends) throw SupportException('Service unavailable', statusCode: 503);
    return SupportMessage(id: 'srv-${sentClientIds.length}', mine: true, body: body, createdAt: '2026-11-11T07:00:00Z');
  }

  @override
  Future<void> markRead(String userId) async => reads.add(userId);
}

/// A real 1x1 PNG, so the photo strip decodes it like a picked photo.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

Widget _app(SupportApi api, {Future<List<XFile>> Function(ImageSource, int)? pick}) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => _FakeAuth('member-1')),
        ChangeNotifierProvider<ConnectivityProvider>(
          create: (_) => ConnectivityProvider(probeUrl: 'http://127.0.0.1:9/health', autoStart: false),
        ),
      ],
      child: MaterialApp(home: SupportThreadScreen(api: api, pickPhotos: pick)),
    );

void main() {
  group('the thread as the backend sends it', () {
    test('no conversation yet reads as an empty thread', () {
      final t = SupportThread.fromJson({'conversation': null, 'messages': [], 'unread': 0});
      expect(t.conversationId, isNull);
      expect(t.messages, isEmpty);
    });

    test('messages keep their order; only the member\'s own are "mine"; photos come as links', () {
      final t = SupportThread.fromJson({
        'conversation': {'id': 'c1', 'ref': 'H24-ABCDEF', 'status': 'waiting'},
        'messages': [
          {
            'id': 'm1', 'author': 'member', 'body': '', 'created_at': '2026-11-11T06:00:00Z',
            'attachments': [
              {'url': 'https://storage.example/signed/a.jpg', 'mime': 'image/jpeg'},
              {'url': '', 'mime': 'image/png'},
              'nonsense',
            ],
          },
          {'id': 'm2', 'author': 'staff', 'body': 'Hi, how can we help?', 'created_at': '2026-11-11T06:05:00Z'},
        ],
        'unread': 1,
      });
      expect(t.ref, 'H24-ABCDEF');
      expect(t.messages.map((m) => m.mine), [true, false]);
      expect(t.messages.first.attachments.map((a) => a.url), ['https://storage.example/signed/a.jpg']);
      expect(t.messages.last.attachments, isEmpty);
      expect(t.unread, 1);
    });

    test('a photo\'s type is read from its bytes: JPEG, PNG and WebP only', () {
      expect(SupportPhoto.sniffMime(_png), 'image/png');
      expect(SupportPhoto.sniffMime(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0])), 'image/jpeg');
      expect(
        SupportPhoto.sniffMime(Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56])),
        'image/webp',
      );
      expect(SupportPhoto.sniffMime(Uint8List.fromList('%PDF-1.7 hello'.codeUnits)), isNull);
      expect(SupportPhoto.sniffMime(Uint8List(0)), isNull);
    });
  });

  group('the screen', () {
    testWidgets('a first visit explains what this is, and opening it marks answers read', (tester) async {
      final api = _FakeApi(SupportThread.empty);
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      expect(find.text('Message Help24'), findsOneWidget);
      expect(find.textContaining('you get a notification'), findsOneWidget);
      expect(api.reads, ['member-1']);
    });

    testWidgets('Help24\'s answers are signed Help24 Support, never a staff name', (tester) async {
      final api = _FakeApi(SupportThread.fromJson({
        'conversation': {'id': 'c1', 'ref': 'H24-ABCDEF', 'status': 'waiting'},
        'messages': [
          {'id': 'm1', 'author': 'member', 'body': 'My payout is late', 'created_at': '2026-11-11T06:00:00Z'},
          {'id': 'm2', 'author': 'staff', 'body': 'It went out this morning.', 'created_at': '2026-11-11T06:05:00Z'},
        ],
        'unread': 1,
      }));
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      expect(find.text('My payout is late'), findsOneWidget);
      expect(find.text('It went out this morning.'), findsOneWidget);
      // The app bar and the label above Help24's answer.
      expect(find.text('Help24 Support'), findsNWidgets(2));
    });

    testWidgets('a message shows at once; a failed one is kept and retried with the same id', (tester) async {
      final api = _FakeApi(SupportThread.empty)..failSends = true;
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Can I change my number?');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Can I change my number?'), findsOneWidget);
      expect(find.text('Not sent. Tap to try again.'), findsOneWidget);

      api.failSends = false;
      await tester.tap(find.text('Not sent. Tap to try again.'));
      await tester.pumpAndSettle();
      expect(find.text('Not sent. Tap to try again.'), findsNothing);
      expect(api.sentClientIds, hasLength(2));
      expect(api.sentClientIds.toSet(), hasLength(1), reason: 'a retry must reuse the client id, or it could be stored twice');
    });

    testWidgets('photos: picked, shown before sending, removable; a photo-only message uploads first, then sends', (tester) async {
      final api = _FakeApi(SupportThread.empty);
      Future<List<XFile>> pick(ImageSource source, int max) async => [
            XFile.fromData(_png, name: 'one.png'),
            XFile.fromData(_png, name: 'two.png'),
            XFile.fromData(Uint8List.fromList('not a photo'.codeUnits), name: 'notes.txt'),
          ];
      await tester.pumpWidget(_app(api, pick: pick));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add a photo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose from your photos'));
      await tester.pumpAndSettle();

      expect(find.text('Only JPG, PNG or WebP photos can be sent.'), findsOneWidget);
      // The notice sits over the composer until it times out.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(_removeButtons, findsNWidgets(2));
      await tester.tap(_removeButtons.first);
      await tester.pumpAndSettle();
      expect(_removeButtons, findsOneWidget);

      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(api.uploadedCounts, [1]);
      expect(api.sentBodies, ['']);
      expect(api.sentPhotoPaths, [
        ['members/member-1/photo-0.png'],
      ]);
      expect(_removeButtons, findsNothing, reason: 'the strip empties once the message is on its way');
    });
  });
}

/// Each staged photo's remove button: its icon carries the label.
final _removeButtons = find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == 'Remove photo');
