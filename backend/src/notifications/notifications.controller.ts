import { BadRequestException, Body, Controller, HttpCode, HttpStatus, Logger, Post } from '@nestjs/common';
import { NotificationsService } from './notifications.service';

/**
 * HTTP surface for push/bell notification operations.
 *
 * POST /notifications/chat-message
 *   Called by the Flutter app after inserting a chat_messages row.
 *   Looks up the recipient, inserts a bell notification, and sends FCM push.
 */
@Controller('notifications')
export class NotificationsController {
  private readonly logger = new Logger(NotificationsController.name);

  constructor(private readonly notifications: NotificationsService) {}

  /**
   * Notify the recipient of a new chat message.
   *
   * Body: { "chatId": "uuid", "senderId": "uid", "messagePreview": "Hello!" }
   *
   * The backend resolves recipient = the other participant in the chat.
   * Android tag is set to chatId so all messages from the same conversation
   * collapse into a single notification slot rather than stacking.
   *
   * Logs: [NOTIFY][CHAT_DB_INSERT], [NOTIFY][CHAT_BELL_CREATED]
   */
  @Post('chat-message')
  @HttpCode(HttpStatus.OK)
  async chatMessage(
    @Body()
    body: {
      chatId?: string;
      senderId?: string;
      messagePreview?: string;
    },
  ) {
    if (!body?.chatId)    throw new BadRequestException('chatId is required');
    if (!body?.senderId)  throw new BadRequestException('senderId is required');

    this.logger.log(`[NOTIFY][CHAT_HTTP] chatId=${body.chatId} senderId=${body.senderId}`);

    return this.notifications.sendChatNotification({
      chatId:          body.chatId,
      senderId:        body.senderId,
      messagePreview:  body.messagePreview ?? '',
    });
  }
}
