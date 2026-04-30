import { IsString, IsNotEmpty } from 'class-validator';

export class ReleasePayoutDto {
  @IsString()
  @IsNotEmpty()
  post_id!: string;
}
