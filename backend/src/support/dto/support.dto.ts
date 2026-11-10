import { IsEmail, IsIn, IsInt, IsOptional, IsString, Matches, MaxLength } from 'class-validator';

/** GET /admin/support/conversations */
export class ListConversationsQueryDto {
  @IsOptional()
  @IsIn(['open', 'waiting', 'closed'])
  status?: 'open' | 'waiting' | 'closed';

  @IsOptional()
  @IsIn(['support', 'general', 'security'])
  label?: 'support' | 'general' | 'security';
}

/** A reply or an internal note. Trimmed and checked again in the service. */
export class SupportTextDto {
  @IsString()
  @MaxLength(10000)
  body: string;
}

export class SupportStatusDto {
  @IsIn(['open', 'waiting', 'closed'])
  status: 'open' | 'waiting' | 'closed';
}

/** Write to someone first. */
export class StartConversationDto {
  @IsEmail()
  @MaxLength(320)
  email: string;

  @IsString()
  @MaxLength(200)
  subject: string;

  @IsString()
  @MaxLength(10000)
  body: string;
}

/**
 * What workers/help24-mail posts: the email as base64 JSON, signed with the
 * shared secret over "<timestamp>.<payload>" (support-rules.ts).
 */
export class InboundDeliveryDto {
  @IsInt()
  timestamp: number;

  @IsString()
  @MaxLength(100000)
  @Matches(/^[A-Za-z0-9+/]+={0,2}$/)
  payload: string;

  @Matches(/^[0-9a-f]{64}$/)
  signature: string;
}
