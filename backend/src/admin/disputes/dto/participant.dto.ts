import {
  ArrayMaxSize,
  ArrayMinSize,
  IsArray,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  MaxLength,
  Min,
  MinLength,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';

/**
 * Participant-facing dispute DTOs (client OR provider). These routes are NOT
 * behind the admin guard; the raiser is identified by user_id and validated by
 * DisputesService.assertParticipant against the post's author/selected provider.
 */

/** POST /disputes/:id/reply — a participant posts a text message to the thread. */
export class ParticipantReplyDto {
  @IsString()
  user_id: string; // Firebase UID (client or provider)

  @IsString()
  @MinLength(1)
  @MaxLength(2000)
  message: string;
}

/** One file in an upload-url request. */
export class UploadFileDto {
  @IsString()
  @MaxLength(255)
  file_name: string;

  @IsString()
  content_type: string; // validated against DisputeStorageService.ALLOWED
}

/** POST /disputes/:id/evidence/upload-url — ask for signed upload URLs. */
export class RequestUploadUrlsDto {
  @IsString()
  user_id: string;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(10) // mirrors DisputeStorageService.MAX_FILES_PER_ACTION
  @ValidateNested({ each: true })
  @Type(() => UploadFileDto)
  files: UploadFileDto[];
}

/** One uploaded object the client is registering as evidence. */
export class SubmitEvidenceItemDto {
  @IsString()
  path: string; // the storage object path returned by upload-url

  @IsString()
  @MaxLength(255)
  file_name: string;

  @IsString()
  mime_type: string;

  @IsOptional()
  @IsInt()
  @Min(0)
  size_bytes?: number;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  caption?: string;
}

/** POST /disputes/:id/evidence/submit — register uploaded objects as evidence. */
export class SubmitEvidenceDto {
  @IsString()
  user_id: string;

  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(10)
  @ValidateNested({ each: true })
  @Type(() => SubmitEvidenceItemDto)
  items: SubmitEvidenceItemDto[];
}

/** POST /disputes/:id/request-evidence — admin requests evidence from a party. */
export class RequestEvidenceDto {
  @IsIn(['client', 'provider'])
  from: 'client' | 'provider';

  @IsString()
  @MinLength(1)
  @MaxLength(2000)
  message: string;
}
