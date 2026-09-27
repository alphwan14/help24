import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsIn,
  IsInt,
  IsNotEmpty,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
  ValidateNested,
} from 'class-validator';
import {
  MAX_EVIDENCE_BYTES,
  MAX_REPORT_EVIDENCE,
  REPORT_CATEGORIES,
  REPORT_EVIDENCE_MIME,
  REPORT_TARGET_TYPES,
  ReportCategory,
  ReportTargetType,
} from '../moderation.constants';

const EVIDENCE_MIME_TYPES = Object.keys(REPORT_EVIDENCE_MIME);

/** One screenshot the reporter uploaded through a signed URL. */
export class ReportEvidenceItemDto {
  // The exact shape ReportEvidenceService issues. The database re-checks the
  // `reports/<reporter>/` prefix against the verified reporter.
  @IsString()
  @MaxLength(300)
  @Matches(/^reports\/[A-Za-z0-9_-]{1,128}\/[0-9a-f-]{36}\.(jpg|png|webp)$/)
  path: string;

  @IsIn(EVIDENCE_MIME_TYPES)
  mime_type: string;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(MAX_EVIDENCE_BYTES)
  size_bytes?: number;
}

export class CreateReportDto {
  /**
   * The reporter. BOUND by the auth guard to the verified caller (the route is
   * @AuthCritical), so a client never needs to send it and cannot choose it.
   * Declared because the guard injects it before validation runs.
   */
  @IsOptional()
  @IsString()
  @MaxLength(128)
  reporter_id?: string;

  @IsIn(REPORT_TARGET_TYPES)
  target_type: ReportTargetType;

  @IsString()
  @IsNotEmpty()
  @MaxLength(128)
  target_id: string;

  @IsIn(REPORT_CATEGORIES)
  category: ReportCategory;

  @IsOptional()
  @IsString()
  @MaxLength(1000)
  details?: string;

  /** Context: the conversation a person was reported from. */
  @IsOptional()
  @IsUUID()
  chat_id?: string;

  /** Context: the listing a person was reported from. */
  @IsOptional()
  @IsUUID()
  post_id?: string;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(MAX_REPORT_EVIDENCE)
  @ValidateNested({ each: true })
  @Type(() => ReportEvidenceItemDto)
  evidence?: ReportEvidenceItemDto[];
}

export class EvidenceFileDto {
  @IsIn(EVIDENCE_MIME_TYPES)
  content_type: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  file_name?: string;
}

export class ReportEvidenceUploadDto {
  /** Bound by the auth guard, as on CreateReportDto. */
  @IsOptional()
  @IsString()
  @MaxLength(128)
  reporter_id?: string;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(MAX_REPORT_EVIDENCE)
  @ValidateNested({ each: true })
  @Type(() => EvidenceFileDto)
  files: EvidenceFileDto[];
}
