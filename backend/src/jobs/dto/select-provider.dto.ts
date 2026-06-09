import { IsString, IsUUID } from 'class-validator';

export class SelectProviderDto {
  @IsUUID()
  post_id: string;

  /** Firebase UID of the provider being selected. */
  @IsString()
  provider_id: string;

  /** Firebase UID of the client (post author) performing the selection. */
  @IsString()
  client_user_id: string;
}
