import { IsBoolean, IsOptional, IsString, MaxLength, MinLength } from 'class-validator';

/** Post a message into the dispute's court thread (admin author). */
export class PostMessageDto {
  @IsString()
  @MinLength(1)
  @MaxLength(2000)
  message: string;

  /** When true the message is an internal admin note — never shown to the
   *  client/provider (participant reads filter it out). Defaults to false. */
  @IsOptional()
  @IsBoolean()
  internal?: boolean;
}
