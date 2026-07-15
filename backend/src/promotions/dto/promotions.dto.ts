import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsNumber,
  IsOptional,
  IsString,
  IsUUID,
  Max,
  MaxLength,
  Min,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { PROMOTION_PLACEMENTS } from '../serving-logic';
import { PROMOTION_EVENT_PLACEMENTS, PROMOTION_EVENT_TYPES } from '../analytics.service';

/**
 * User-facing DTOs. The asserted `user_id` convention matches jobs/mpesa —
 * when the platform-wide Firebase-token guard lands, these routes adopt it at
 * the controller in one place.
 */

export class CreateCampaignDto {
  @IsString()
  @MinLength(1)
  user_id!: string;

  @IsUUID()
  post_id!: string;

  @IsString()
  @MinLength(1)
  @MaxLength(64)
  package_id!: string;
}

export class PayCampaignDto {
  @IsString()
  @MinLength(1)
  user_id!: string;

  /** Optional M-Pesa number override; defaults to the payer's profile number. */
  @IsOptional()
  @IsString()
  @MaxLength(20)
  phone?: string;
}

export class OwnerActionDto {
  @IsString()
  @MinLength(1)
  user_id!: string;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  reason?: string;
}

export class SlotsQueryDto {
  @IsIn(PROMOTION_PLACEMENTS)
  placement!: (typeof PROMOTION_PLACEMENTS)[number];

  @IsOptional()
  @IsString()
  @MaxLength(80)
  category?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  q?: string;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(-90)
  @Max(90)
  lat?: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(-180)
  @Max(180)
  lng?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(10)
  limit?: number;
}

export class PromotionEventDto {
  @IsUUID()
  campaign_id!: string;

  @IsIn(PROMOTION_EVENT_TYPES)
  event_type!: (typeof PROMOTION_EVENT_TYPES)[number];

  @IsOptional()
  @IsIn(PROMOTION_EVENT_PLACEMENTS)
  placement?: (typeof PROMOTION_EVENT_PLACEMENTS)[number];

  @IsOptional()
  @IsString()
  @MaxLength(128)
  viewer_user_id?: string;
}

export class IngestEventsDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => PromotionEventDto)
  events!: PromotionEventDto[];
}

// ── Admin ─────────────────────────────────────────────────────────────────────

export class RejectCampaignDto {
  @IsString()
  @MinLength(3)
  @MaxLength(500)
  reason!: string;
}

export class AdminCancelDto {
  @IsString()
  @MinLength(3)
  @MaxLength(500)
  reason!: string;
}

export class UpdatePackageDto {
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(60)
  name?: string;

  @IsOptional()
  @IsString()
  @MaxLength(300)
  description?: string;

  /** Whole KES; null only permitted for custom (enterprise) packages. */
  @IsOptional()
  @IsInt()
  @Min(1)
  price_kes?: number;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(365)
  duration_days?: number;

  @IsOptional()
  @IsInt()
  sort?: number;

  @IsOptional()
  @IsBoolean()
  active?: boolean;
}
