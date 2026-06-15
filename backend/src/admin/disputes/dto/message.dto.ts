import { IsString, MaxLength, MinLength } from 'class-validator';

/** Post a message into the dispute's court thread (admin author). */
export class PostMessageDto {
  @IsString()
  @MinLength(1)
  @MaxLength(2000)
  message: string;
}
