import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsBoolean,
  IsIn,
  IsInt,
  IsNumber,
  IsOptional,
  IsString,
  Max,
  MaxLength,
  Min,
  MinLength,
  ValidateNested,
} from 'class-validator';

/** Every interaction the client may report. Mirrors the CHECK in migration 091. */
export const INTERACTION_KINDS = [
  'impression',
  'open',
  'save',
  'unsave',
  'apply',
  'message',
  'hire',
  'search',
  'category_open',
  'profile_open',
] as const;

export type InteractionKind = (typeof INTERACTION_KINDS)[number];

/** Feed tabs. `all` means requests + offers, matching the Discover tab bar. */
export const FEED_SCOPES = ['all', 'requests', 'offers', 'jobs'] as const;
export type FeedScope = (typeof FEED_SCOPES)[number];

/**
 * `GET /feed` query. Everything is optional: an anonymous, location-less,
 * filter-less request is the cold-start case and must work.
 *
 * Numbers arrive as query strings, hence `@Type(() => Number)` throughout.
 */
export class FeedQueryDto {
  /** Firebase UID. Absent = anonymous browsing (no personalisation). */
  @IsOptional()
  @IsString()
  @MaxLength(128)
  user_id?: string;

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

  /** Viewer's UTC offset in minutes (Nairobi = 180). Drives the time-of-day signal. */
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(-840)
  @Max(840)
  tz_offset?: number;

  @IsOptional()
  @IsIn(FEED_SCOPES)
  scope?: FeedScope;

  /** Comma-separated category NAMES, matching `posts.category`. */
  @IsOptional()
  @IsString()
  @MaxLength(1000)
  categories?: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  q?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  city?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  area?: string;

  @IsOptional()
  @IsIn(['urgent', 'soon', 'flexible'])
  urgency?: string;

  @IsOptional()
  @IsString()
  @MaxLength(40)
  difficulty?: string;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(0)
  min_price?: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(0)
  max_price?: number;

  /** Search radius in km for the `nearby` retrieval pool. */
  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(1)
  @Max(2000)
  radius_km?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  page?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(50)
  page_size?: number;

  /**
   * Include raw signal inputs and the diversity trace. Costs an extra call per
   * signal per candidate, so it is opt-in — it is a tuning instrument, not a
   * production default.
   */
  @IsOptional()
  @IsIn(['0', '1', 'true', 'false'])
  explain?: string;
}

/** One behavioural event. All subject fields are optional by kind. */
export class InteractionDto {
  @IsIn(INTERACTION_KINDS)
  kind!: InteractionKind;

  @IsOptional()
  @IsString()
  @MaxLength(128)
  post_id?: string;

  @IsOptional()
  @IsString()
  @MaxLength(128)
  author_id?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  category?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  profession?: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  query?: string;
}

/**
 * `POST /feed/interactions`. Batched exactly like `PromotionTracker`: the
 * client buffers and flushes, and the endpoint answers 202 whatever happens —
 * analytics must never surface as an error to someone browsing a feed.
 */
export class IngestInteractionsDto {
  @IsString()
  @MinLength(1)
  @MaxLength(128)
  user_id!: string;

  @IsArray()
  @ArrayMaxSize(100)
  @ValidateNested({ each: true })
  @Type(() => InteractionDto)
  events!: InteractionDto[];
}

/** `POST /feed/availability` — the provider's "available now" window. */
export class SetAvailabilityDto {
  @IsString()
  @MinLength(1)
  @MaxLength(128)
  user_id!: string;

  /** true = available now, false = clear the window. */
  @IsBoolean()
  available!: boolean;

  /** How long the window lasts. Capped at 24 h so it always expires. */
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(24)
  hours?: number;
}
