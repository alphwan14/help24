import { IsIn, IsOptional, IsString, IsUrl, MaxLength } from 'class-validator';

/**
 * Attach evidence to a dispute. Posted by an admin on behalf of the case (or
 * the system). Either file_url (image/video) or content (text) must be present;
 * the service validates the pairing.
 */
export class AddEvidenceDto {
  @IsIn(['image', 'video', 'text', 'system_chat'])
  type: 'image' | 'video' | 'text' | 'system_chat';

  @IsIn(['client', 'provider', 'admin', 'system'])
  uploader_type: 'client' | 'provider' | 'admin' | 'system';

  @IsOptional()
  @IsUrl()
  file_url?: string;

  @IsOptional()
  @IsString()
  @MaxLength(5000)
  content?: string;
}
