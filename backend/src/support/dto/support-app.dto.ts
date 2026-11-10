import { Type } from 'class-transformer';
import { ArrayMaxSize, IsArray, IsIn, IsOptional, IsString, IsUUID, MaxLength, ValidateNested } from 'class-validator';

/** POST /support/app/messages — a member's message from the app. */
export class AppSupportMessageDto {
  @IsString()
  user_id: string; // Firebase UID, bound to the signed-in member

  /** May be empty when the message carries photos; the service checks. */
  @IsString()
  @MaxLength(10000)
  body: string;

  /** The app's own id for this message, so a retried send is stored once. */
  @IsUUID()
  client_id: string;

  /** Storage paths from POST /support/app/attachments, already uploaded (migration 143). */
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(5)
  @IsString({ each: true })
  @MaxLength(200, { each: true })
  attachments?: string[];
}

/** POST /support/app/read — the member opened their thread. */
export class AppSupportReadDto {
  @IsString()
  user_id: string; // Firebase UID, bound to the signed-in member
}

export class AppUploadFileDto {
  @IsIn(['image/jpeg', 'image/png', 'image/webp'])
  content_type: string;
}

/** POST /support/app/attachments — signed upload links for up to 5 photos. */
export class AppUploadUrlsDto {
  @IsString()
  user_id: string; // Firebase UID, bound to the signed-in member

  @IsArray()
  @ArrayMaxSize(5)
  @ValidateNested({ each: true })
  @Type(() => AppUploadFileDto)
  files: AppUploadFileDto[];
}
