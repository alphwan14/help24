import {
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  MaxLength,
  Min,
} from 'class-validator';

export const DECISION_TYPES = [
  'FULL_REFUND',
  'FULL_RELEASE',
  'PARTIAL_SPLIT',
  'ESCALATE',
] as const;
export type DecisionType = (typeof DECISION_TYPES)[number];

/**
 * Binding ruling on a dispute. Written immutably to dispute_decisions.
 *
 *  FULL_RELEASE  → pay the provider (automated M-Pesa B2C)
 *  FULL_REFUND   → refund the client (recorded; cash processed manually)
 *  PARTIAL_SPLIT → requires provider_amount + client_refund_amount
 *  ESCALATE      → bump to super_admin; no money moves
 */
export class DecisionDto {
  @IsIn(DECISION_TYPES)
  decision_type: DecisionType;

  @IsOptional()
  @IsInt()
  @Min(0)
  provider_amount?: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  client_refund_amount?: number;

  @IsString()
  @MaxLength(2000)
  reasoning: string;
}
