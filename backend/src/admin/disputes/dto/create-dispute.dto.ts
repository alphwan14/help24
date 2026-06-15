import { IsIn, IsString, IsUUID, MaxLength } from 'class-validator';

/**
 * Raise a dispute on a job. User-facing (client OR provider) — NOT an admin
 * action, so this route is not behind the admin guard. The raiser is identified
 * by raised_by_user_id and must be a participant of the post.
 */
export class CreateDisputeDto {
  @IsUUID()
  post_id: string;

  @IsString()
  raised_by_user_id: string; // Firebase UID (client or provider)

  @IsIn(['client', 'provider'])
  raised_by_role: 'client' | 'provider';

  @IsString()
  @MaxLength(1000)
  reason: string;
}
