import { IsInt, IsOptional, IsString, IsNotEmpty, IsUUID, Max, MaxLength, Min } from 'class-validator';

/**
 * Submit a review for a completed job. The reviewer is the post's CLIENT; the
 * reviewee is the selected provider. Eligibility is fully re-validated in the
 * service — this DTO only checks shape.
 */
export class CreateReviewDto {
  @IsUUID()
  post_id: string;

  @IsString()
  @IsNotEmpty()
  client_id: string; // Firebase UID of the reviewer (must equal post author)

  @IsInt()
  @Min(1)
  @Max(5)
  rating: number;

  @IsOptional()
  @IsString()
  @MaxLength(1000)
  comment?: string;
}
