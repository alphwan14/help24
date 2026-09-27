import { Type } from 'class-transformer';
import {
  IsBoolean,
  IsIn,
  IsInt,
  IsISO8601,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
  MinLength,
} from 'class-validator';
import {
  ACTION_TYPES,
  REPORT_CATEGORIES,
  REPORT_STATUSES,
  REPORT_TARGET_TYPES,
  SANCTION_KINDS,
  SEVERITIES,
  SanctionKind,
} from '../moderation.constants';

/** A Help24 account id (a Firebase UID). Validated in the path, not trusted. */
export const USER_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

export class ListReportsQueryDto {
  /** A status, or `open` for every status still awaiting a decision. */
  @IsOptional()
  @IsIn([...REPORT_STATUSES, 'open', 'closed'])
  status?: string;

  @IsOptional()
  @IsIn(SEVERITIES)
  severity?: string;

  @IsOptional()
  @IsIn(REPORT_CATEGORIES)
  category?: string;

  @IsOptional()
  @IsIn(REPORT_TARGET_TYPES)
  target_type?: string;

  @IsOptional()
  @Matches(USER_ID_PATTERN)
  reported_user_id?: string;

  @IsOptional()
  @Matches(USER_ID_PATTERN)
  reporter_id?: string;

  /** `me`, `none`, or an admin id. */
  @IsOptional()
  @Matches(/^(me|none|[0-9a-f-]{36})$/)
  assigned?: string;

  @IsOptional()
  @IsISO8601()
  from?: string;

  @IsOptional()
  @IsISO8601()
  to?: string;

  /** A report reference (8 hex), an account id, or words from the details. */
  @IsOptional()
  @IsString()
  @MaxLength(100)
  q?: string;

  /** `queue` = most serious first, oldest first. `newest` = most recent first. */
  @IsOptional()
  @IsIn(['queue', 'newest'])
  sort?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(10_000)
  offset?: number;
}

export class TriageReportDto {
  @IsOptional()
  @IsIn(['under_review', 'action_required'])
  status?: 'under_review' | 'action_required';

  @IsOptional()
  @IsIn(SEVERITIES)
  severity?: string;

  /** `me` claims the report; `none` releases it. */
  @IsOptional()
  @IsIn(['me', 'none'])
  assign?: 'me' | 'none';

  /** Hand the report to another admin (senior_admin and above). */
  @IsOptional()
  @IsUUID()
  assign_to?: string;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  reason?: string;
}

export class ResolveReportDto {
  @IsIn(['resolved', 'dismissed'])
  outcome: 'resolved' | 'dismissed';

  @IsString()
  @MinLength(5)
  @MaxLength(1000)
  reason: string;

  @IsOptional()
  @IsString()
  @MaxLength(4000)
  internal_note?: string;
}

export class NoteDto {
  @IsString()
  @MinLength(1)
  @MaxLength(4000)
  note: string;
}

export class SanctionDto {
  @IsIn(SANCTION_KINDS)
  kind: SanctionKind;

  /** SHOWN TO THE USER. Private reasoning belongs in internal_note. */
  @IsString()
  @MinLength(10)
  @MaxLength(1000)
  reason: string;

  @IsOptional()
  @IsString()
  @MaxLength(4000)
  internal_note?: string;

  /** Required for a suspension; optional for messaging/marketplace; refused for warning/ban. */
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(365)
  duration_days?: number;

  @IsOptional()
  @IsUUID()
  report_id?: string;

  @IsOptional()
  @IsBoolean()
  resolve_report?: boolean;

  @IsOptional()
  @IsBoolean()
  hide_listings?: boolean;
}

export class LiftRestrictionDto {
  @IsString()
  @MinLength(10)
  @MaxLength(1000)
  reason: string;

  @IsOptional()
  @IsString()
  @MaxLength(4000)
  internal_note?: string;
}

export class ContentActionDto {
  @IsString()
  @MinLength(10)
  @MaxLength(1000)
  reason: string;

  @IsOptional()
  @IsString()
  @MaxLength(4000)
  internal_note?: string;

  @IsOptional()
  @IsUUID()
  report_id?: string;
}

export class RestrictedQueryDto {
  @IsOptional()
  @IsIn(['suspension', 'ban', 'messaging', 'marketplace'])
  kind?: string;
}

export class AuditQueryDto {
  @IsOptional()
  @IsUUID()
  admin_id?: string;

  @IsOptional()
  @IsIn(ACTION_TYPES)
  action_type?: string;

  @IsOptional()
  @Matches(USER_ID_PATTERN)
  user_id?: string;

  @IsOptional()
  @IsUUID()
  report_id?: string;

  @IsOptional()
  @IsISO8601()
  from?: string;

  @IsOptional()
  @IsISO8601()
  to?: string;

  /** A reference quoted by a user or an admin: the first hex of an action id. */
  @IsOptional()
  @Matches(/^[0-9A-Fa-f]{4,32}$/)
  ref?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(200)
  limit?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(100_000)
  offset?: number;
}
