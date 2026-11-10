import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Resend } from 'resend';

export interface OutboundEmail {
  from: string;
  to: string;
  replyTo: string;
  subject: string;
  text: string;
  html: string;
  /** Message-ID, In-Reply-To, References: so the member's mail client threads it. */
  headers: Record<string, string>;
  /** Our message id: a retried send of the same message is not delivered twice. */
  idempotencyKey: string;
}

/** Why a reply could not be sent; shown to the admin next to the message. */
export class MailNotSentError extends Error {}

/**
 * Sends support email through Resend, the provider already verified for
 * help24.co.ke (it signs the auth emails Supabase sends as security@).
 * RESEND_API_KEY unset = sending is off: every reply is kept and marked
 * "not sent", never lost.
 */
@Injectable()
export class SupportMailerService {
  private readonly logger = new Logger(SupportMailerService.name);
  private client: Resend | null | undefined;

  constructor(private readonly config: ConfigService) {}

  private resend(): Resend | null {
    if (this.client === undefined) {
      const key = this.config.get<string>('RESEND_API_KEY')?.trim();
      this.client = key ? new Resend(key) : null;
      if (!key) this.logger.warn('[SUPPORT] RESEND_API_KEY is not set — support replies are stored but not emailed.');
    }
    return this.client;
  }

  /** Sends one email; throws MailNotSentError with a reason an admin can act on. */
  async send(mail: OutboundEmail): Promise<{ providerId: string | null }> {
    const resend = this.resend();
    if (!resend) throw new MailNotSentError('Email sending is not set up on the server (RESEND_API_KEY).');
    try {
      const { data, error } = await resend.emails.send(
        {
          from: mail.from,
          to: mail.to,
          replyTo: mail.replyTo,
          subject: mail.subject,
          text: mail.text,
          html: mail.html,
          headers: mail.headers,
        },
        { idempotencyKey: mail.idempotencyKey },
      );
      if (error) throw new MailNotSentError(`The email provider refused it: ${error.message}`.slice(0, 500));
      return { providerId: data?.id ?? null };
    } catch (e) {
      if (e instanceof MailNotSentError) throw e;
      throw new MailNotSentError(`The email provider could not be reached: ${e instanceof Error ? e.message : String(e)}`.slice(0, 500));
    }
  }
}
