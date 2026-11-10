import 'dart:typed_data';

/// Message Help24: the member's one conversation with Help24 (backend
/// /support/app/*, migrations 142 and 143). Staff answers are always signed
/// "Help24 Support"; the app never learns which admin wrote one.
class SupportThread {
  /// Null until the member sends their first message.
  final String? conversationId;
  final String? ref;
  final List<SupportMessage> messages;

  /// Answers the member has not opened yet.
  final int unread;

  const SupportThread({this.conversationId, this.ref, this.messages = const [], this.unread = 0});

  static const empty = SupportThread();

  factory SupportThread.fromJson(Map<String, dynamic> json) {
    final conversation = json['conversation'];
    final raw = json['messages'];
    return SupportThread(
      conversationId: conversation is Map ? conversation['id'] as String? : null,
      ref: conversation is Map ? conversation['ref'] as String? : null,
      messages: raw is List
          ? [
              for (final m in raw)
                if (m is Map<String, dynamic>) SupportMessage.fromJson(m),
            ]
          : const [],
      unread: json['unread'] is int ? json['unread'] as int : 0,
    );
  }
}

/// Where a message the member wrote stands on this phone.
enum SupportSendState { sent, sending, failed }

/// A photo on a message, as the backend shows it: a short-lived signed link.
class SupportAttachment {
  final String url;
  final String mime;
  const SupportAttachment({required this.url, required this.mime});

  static SupportAttachment? fromJson(Object? json) {
    if (json is! Map) return null;
    final url = json['url'];
    if (url is! String || url.isEmpty) return null;
    return SupportAttachment(url: url, mime: json['mime'] as String? ?? 'image/jpeg');
  }
}

/// A photo the member picked, still on the phone.
class SupportPhoto {
  final Uint8List bytes;
  final String mime;
  const SupportPhoto({required this.bytes, required this.mime});

  /// The photo's real type from its first bytes (JPEG, PNG or WebP), or null
  /// for anything else. The private bucket refuses other types anyway; this
  /// says so before a slow upload instead of after.
  static String? sniffMime(Uint8List b) {
    if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    if (b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return 'image/png';
    if (b.length > 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }
}

class SupportMessage {
  final String id;

  /// True for the member's own messages; false for Help24's answers.
  final bool mine;

  /// May be empty when the message is photos only.
  final String body;

  /// Server time (UTC ISO), or the local send time for a message in flight.
  final String createdAt;
  final SupportSendState state;

  /// The id the app sent it with, so a retry is stored once.
  final String? clientId;

  /// Photos as stored: signed links from the backend.
  final List<SupportAttachment> attachments;

  /// Photos still on this phone, shown while a message is in flight or not sent.
  final List<SupportPhoto> localPhotos;

  const SupportMessage({
    required this.id,
    required this.mine,
    required this.body,
    required this.createdAt,
    this.state = SupportSendState.sent,
    this.clientId,
    this.attachments = const [],
    this.localPhotos = const [],
  });

  factory SupportMessage.fromJson(Map<String, dynamic> json) {
    final raw = json['attachments'];
    return SupportMessage(
      id: json['id'] as String? ?? '',
      mine: json['author'] == 'member',
      body: json['body'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
      attachments: raw is List
          ? [
              for (final a in raw)
                if (SupportAttachment.fromJson(a) case final SupportAttachment att) att,
            ]
          : const [],
    );
  }

  SupportMessage copyWith({
    String? id,
    String? createdAt,
    SupportSendState? state,
    List<SupportAttachment>? attachments,
    List<SupportPhoto>? localPhotos,
  }) =>
      SupportMessage(
        id: id ?? this.id,
        mine: mine,
        body: body,
        createdAt: createdAt ?? this.createdAt,
        state: state ?? this.state,
        clientId: clientId,
        attachments: attachments ?? this.attachments,
        localPhotos: localPhotos ?? this.localPhotos,
      );
}
