/// Message Help24: the member's one conversation with Help24 (backend
/// /support/app/*, migration 142). Staff answers are always signed "Help24
/// Support"; the app never learns which admin wrote one.
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

class SupportMessage {
  final String id;

  /// True for the member's own messages; false for Help24's answers.
  final bool mine;
  final String body;

  /// Server time (UTC ISO), or the local send time for a message in flight.
  final String createdAt;
  final SupportSendState state;

  /// The id the app sent it with, so a retry is stored once.
  final String? clientId;

  const SupportMessage({
    required this.id,
    required this.mine,
    required this.body,
    required this.createdAt,
    this.state = SupportSendState.sent,
    this.clientId,
  });

  factory SupportMessage.fromJson(Map<String, dynamic> json) => SupportMessage(
        id: json['id'] as String? ?? '',
        mine: json['author'] == 'member',
        body: json['body'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
      );

  SupportMessage copyWith({String? id, String? createdAt, SupportSendState? state}) => SupportMessage(
        id: id ?? this.id,
        mine: mine,
        body: body,
        createdAt: createdAt ?? this.createdAt,
        state: state ?? this.state,
        clientId: clientId,
      );
}
