import { IsString, IsUUID, MaxLength, MinLength } from 'class-validator';

/** POST /support/app/messages — a member's message from the app. */
export class AppSupportMessageDto {
  @IsString()
  user_id: string; // Firebase UID, bound to the signed-in member

  @IsString()
  @MinLength(1)
  @MaxLength(10000)
  body: string;

  /** The app's own id for this message, so a retried send is stored once. */
  @IsUUID()
  client_id: string;
}

/** POST /support/app/read — the member opened their thread. */
export class AppSupportReadDto {
  @IsString()
  user_id: string; // Firebase UID, bound to the signed-in member
}
