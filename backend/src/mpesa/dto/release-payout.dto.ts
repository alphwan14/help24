import { IsString, IsNotEmpty, IsUUID } from 'class-validator';

export class ReleasePayoutDto {
  @IsString()
  @IsNotEmpty()
  post_id!: string;

  @IsUUID('4')
  provider_id!: string;
}
