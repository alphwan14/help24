import 'package:help24/models/post_model.dart';

/// The same conversation, message for message, rendered before and after the
/// redesign — taken from the design canvas ("Hello", the Front Gate pin, the
/// offline contract).
class ChatFixtures {
  ChatFixtures._();

  /// Today at [h]:[m] local — bubbles only show the clock, so a fixed day
  /// keeps every screenshot reading the same.
  static DateTime at(int h, int m, {int daysAgo = 0, int second = 0}) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day - daysAgo, h, m, second);
  }

  static int _seq = 0;
  static String _id() {
    _seq++;
    final n = _seq.toRadixString(16).padLeft(12, '0');
    return '7f3c2a10-1b2c-4d5e-8f90-$n';
  }

  static Message text(String body, {required bool mine, required DateTime t, String status = 'sent', DateTime? deliveredAt, String? id}) =>
      Message(
        id: id ?? _id(),
        senderId: mine ? 'me' : 'them',
        text: body,
        timestamp: t,
        isMe: mine,
        status: status,
        deliveredAt: deliveredAt,
      );

  static Message pending(String body, {required DateTime t, required String status, String type = 'text', String? localPath}) =>
      Message(
        id: 'pending_${_id()}',
        senderId: 'me',
        text: body,
        timestamp: t,
        isMe: true,
        type: type,
        status: status,
        localPath: localPath,
      );

  static Message photo({required bool mine, required DateTime t, String caption = 'Image', String status = 'sent'}) {
    final id = _id();
    return Message(
      id: id,
      senderId: mine ? 'me' : 'them',
      text: caption,
      timestamp: t,
      isMe: mine,
      type: 'image',
      status: status,
      attachmentUrl: 'chat-attachments/0b5a1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d/$id.jpg',
    );
  }

  static Message file({required bool mine, required DateTime t, String name = 'help24_contract_offline.pdf', String status = 'sent'}) {
    final id = _id();
    return Message(
      id: id,
      senderId: mine ? 'me' : 'them',
      text: name,
      timestamp: t,
      isMe: mine,
      type: 'file',
      status: status,
      attachmentUrl: 'chat-attachments/0b5a1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d/$id.pdf',
    );
  }

  static Message place(String label, {required bool mine, required DateTime t, String status = 'sent'}) => Message(
        id: _id(),
        senderId: mine ? 'me' : 'them',
        text: label,
        timestamp: t,
        isMe: mine,
        type: 'location',
        latitude: -1.2345,
        longitude: 36.8312,
        status: status,
      );

  /// Where the viewer stands for "1.8 km away".
  static const double viewerLat = -1.2213;
  static const double viewerLng = 36.8215;
}
