import { IsIn, IsInt, IsOptional, IsString, IsUUID, Min } from 'class-validator';

export type DisputeAction = 'release_full' | 'refund_full' | 'partial_split';

export class ResolveDisputeDto {
  @IsUUID()
  dispute_id: string;

  @IsIn(['release_full', 'refund_full', 'partial_split'])
  action: DisputeAction;

  /** Required when action = 'partial_split'. Amount (KES) to release to provider. */
  @IsOptional()
  @IsInt()
  @Min(0)
  provider_amount?: number;

  /** Required when action = 'partial_split'. Amount (KES) to refund to buyer. */
  @IsOptional()
  @IsInt()
  @Min(0)
  buyer_refund?: number;

  /** Admin identifier shown in dispute timeline. */
  @IsString()
  resolved_by: string;

  @IsOptional()
  @IsString()
  admin_notes?: string;
}
