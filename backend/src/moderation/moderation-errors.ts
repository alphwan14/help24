import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  HttpException,
  HttpStatus,
  NotFoundException,
  ServiceUnavailableException,
} from '@nestjs/common';

/** The shape the Supabase client returns for a Postgres error. */
export interface PgError {
  code?: string;
  message?: string;
}

/**
 * Translate a database refusal into an HTTP error.
 *
 * Migrations 114–115 raise every deliberate refusal as
 * `HELP24_<CODE>: <human sentence>`. The CODE becomes a stable machine code in
 * the response (clients branch on it, never on prose); the sentence is already
 * written for a person and is passed through. Anything unrecognised is an
 * infrastructure fault: 503 with a generic sentence, and the caller logs the
 * detail.
 */
export function toHttpError(error: PgError): HttpException {
  const message = error.message ?? '';
  const marker = /HELP24_([A-Z_]+):\s*([\s\S]*)$/.exec(message);

  if (marker) {
    const code = marker[1];
    const human = sentence(marker[2]);
    switch (code) {
      case 'REPORT_SELF':
        return new BadRequestException({ code, message: "You can't report yourself." });
      case 'REPORT_DUPLICATE':
        return new ConflictException({ code, message: "You've already reported this. Our team will review it." });
      case 'REPORT_LIMIT':
        return new HttpException(
          { statusCode: 429, code, message: "You've sent a lot of reports today. Please try again tomorrow." },
          HttpStatus.TOO_MANY_REQUESTS,
        );
      case 'REPORT_NOT_PARTICIPANT':
        return new ForbiddenException({ code, message: human });
      case 'REPORT_INVALID_TARGET':
      case 'REPORT_INVALID_CATEGORY':
      case 'REPORT_INVALID_EVIDENCE':
        return new BadRequestException({ code, message: human });
      case 'MODERATION_NOT_FOUND':
        return new NotFoundException({ code, message: human });
      case 'MODERATION_CONFLICT':
        return new ConflictException({ code, message: human });
      case 'MODERATION_SELF':
      case 'ADMIN_INVALID':
      case 'MODERATION_FORBIDDEN':
        return new ForbiddenException({ code, message: human });
      case 'MODERATION_INVALID':
      case 'MODERATION_NO_CHANGE':
        return new BadRequestException({ code, message: human });
    }
  }

  if (error.code === '23505') {
    return new ConflictException({ code: 'CONFLICT', message: 'That has already been done.' });
  }
  if (error.code === '23503') {
    return new BadRequestException({ code: 'UNKNOWN_ACCOUNT', message: 'That account does not exist.' });
  }

  return new ServiceUnavailableException({
    code: 'MODERATION_UNAVAILABLE',
    message: 'Trust & Safety is temporarily unavailable. Please try again shortly.',
  });
}

/** True when the refusal is the one-open-report-per-target rule. */
export function isDuplicateReport(error: PgError): boolean {
  const message = error.message ?? '';
  return (
    message.includes('HELP24_REPORT_DUPLICATE') ||
    (error.code === '23505' && message.includes('user_reports_one_open_per_target'))
  );
}

function sentence(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return 'That request could not be completed.';
  const first = trimmed.charAt(0).toUpperCase() + trimmed.slice(1);
  return /[.!?]$/.test(first) ? first : `${first}.`;
}
