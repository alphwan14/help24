import { Injectable, Logger } from '@nestjs/common';
import { SupabaseService } from '../../supabase/supabase.service';
import { DecisionType } from './dto/decision.dto';

export interface DisputeRecommendation {
  suggested_decision: DecisionType;
  confidence: number; // 0–100
  reasoning: string;
  signals: Record<string, unknown>;
}

/**
 * Advisory suggestion engine. Analyses case signals and proposes a decision with
 * a confidence score. STRICTLY ADVISORY — the admin always decides. It performs
 * no writes and never moves money.
 *
 * Heuristic model (transparent on purpose — reviewers must be able to reason
 * about why a suggestion was made):
 *   • job completion state (did the provider mark it done / was it approved?)
 *   • evidence balance (which side actually submitted proof?)
 *   • provider proof presence (image/video/file from the provider)
 *   • engagement (chat depth — silence vs. active back-and-forth)
 *   • time delay (how long the job sat before dispute)
 */
@Injectable()
export class DisputeRecommendationService {
  private readonly logger = new Logger(DisputeRecommendationService.name);

  constructor(private readonly supabase: SupabaseService) {}

  async analyze(disputeId: string): Promise<DisputeRecommendation> {
    const { data: dispute } = await this.supabase.client
      .from('disputes')
      .select('id, post_id, transaction_id, raised_by_role, created_at, job_completion_id')
      .eq('id', disputeId)
      .single();

    if (!dispute) {
      return {
        suggested_decision: 'ESCALATE',
        confidence: 0,
        reasoning: 'Dispute not found — cannot analyse.',
        signals: {},
      };
    }

    const postId = dispute.post_id as string;
    const raisedByRole = (dispute.raised_by_role as string) ?? 'client';

    const [completion, evidence, chatCount, post] = await Promise.all([
      this.completionState(postId),
      this.evidenceBreakdown(disputeId),
      this.chatDepth(postId),
      this.supabase.client.from('posts').select('created_at').eq('id', postId).maybeSingle()
        .then((r) => r.data),
    ]);

    // ── Weighted scoring toward provider (release) vs client (refund) ───────────
    // score > 0 leans release-to-provider; score < 0 leans refund-to-client.
    let score = 0;
    const reasons: string[] = [];

    if (completion === 'approved') {
      score += 40;
      reasons.push('Job was already approved by the client before dispute — strong provider signal.');
    } else if (completion === 'pending_approval' || completion === 'disputed') {
      score += 10;
      reasons.push('Provider marked the job complete (awaiting/!disputed approval).');
    } else {
      score -= 15;
      reasons.push('No completion was ever submitted by the provider.');
    }

    if (evidence.providerProof > 0 && evidence.clientProof === 0) {
      score += 25;
      reasons.push(`Only the provider submitted proof (${evidence.providerProof} item(s)).`);
    } else if (evidence.clientProof > 0 && evidence.providerProof === 0) {
      score -= 25;
      reasons.push(`Only the client submitted proof (${evidence.clientProof} item(s)).`);
    } else if (evidence.providerProof > 0 && evidence.clientProof > 0) {
      reasons.push('Both sides submitted evidence — contested; leans toward a split.');
    } else {
      reasons.push('No evidence submitted by either party yet.');
    }

    // Who raised it nudges the prior slightly (the raiser is the aggrieved party).
    if (raisedByRole === 'client') {
      score -= 8;
      reasons.push('Raised by the client (alleging non-delivery).');
    } else {
      score += 8;
      reasons.push('Raised by the provider (alleging non-payment/approval).');
    }

    if (chatCount < 3) {
      reasons.push('Very little chat history — low engagement, weak basis for either side.');
    } else if (chatCount >= 15) {
      reasons.push('Extensive chat history — active engagement between parties.');
    }

    // Stale jobs (long gap before dispute) reduce confidence in any auto-call.
    const ageDays = post?.created_at
      ? (Date.now() - new Date(post.created_at as string).getTime()) / 86_400_000
      : 0;
    if (ageDays > 14) {
      reasons.push(`Job is ${Math.round(ageDays)} days old — staleness lowers confidence.`);
    }

    // ── Map score → decision + confidence ───────────────────────────────────────
    let suggested: DecisionType;
    let confidence: number;

    const bothSubmitted = evidence.providerProof > 0 && evidence.clientProof > 0;
    if (bothSubmitted && Math.abs(score) < 25) {
      suggested = 'PARTIAL_SPLIT';
      confidence = 55;
      reasons.unshift('Recommendation: PARTIAL_SPLIT — contested with evidence on both sides.');
    } else if (score >= 35) {
      suggested = 'FULL_RELEASE';
      confidence = Math.min(95, 50 + score);
      reasons.unshift('Recommendation: FULL_RELEASE — evidence favours the provider.');
    } else if (score <= -35) {
      suggested = 'FULL_REFUND';
      confidence = Math.min(95, 50 + Math.abs(score));
      reasons.unshift('Recommendation: FULL_REFUND — evidence favours the client.');
    } else {
      suggested = 'ESCALATE';
      confidence = 35;
      reasons.unshift('Recommendation: ESCALATE — signals are weak/ambiguous; human judgment needed.');
    }

    // Staleness/low-engagement haircut on confidence.
    if (ageDays > 14) confidence = Math.max(20, confidence - 10);
    if (chatCount < 3) confidence = Math.max(20, confidence - 5);

    const recommendation: DisputeRecommendation = {
      suggested_decision: suggested,
      confidence: Math.round(confidence),
      reasoning: reasons.join(' '),
      signals: {
        score,
        completion_state: completion,
        provider_proof: evidence.providerProof,
        client_proof: evidence.clientProof,
        chat_messages: chatCount,
        job_age_days: Math.round(ageDays),
        raised_by_role: raisedByRole,
      },
    };

    this.logger.log(
      `[RECOMMEND] dispute=${disputeId} → ${suggested} (${recommendation.confidence}%) score=${score}`,
    );
    return recommendation;
  }

  // ── Signal collectors ────────────────────────────────────────────────────────

  private async completionState(postId: string): Promise<string> {
    const { data } = await this.supabase.client
      .from('job_completions')
      .select('status')
      .eq('post_id', postId)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    return (data?.status as string) ?? 'none';
  }

  private async evidenceBreakdown(disputeId: string): Promise<{ providerProof: number; clientProof: number }> {
    const { data } = await this.supabase.client
      .from('dispute_evidence')
      .select('uploader_type, type')
      .eq('dispute_id', disputeId);
    let providerProof = 0;
    let clientProof = 0;
    for (const row of data ?? []) {
      if (row.uploader_type === 'provider') providerProof += 1;
      if (row.uploader_type === 'client') clientProof += 1;
    }
    return { providerProof, clientProof };
  }

  private async chatDepth(postId: string): Promise<number> {
    const { data: chat } = await this.supabase.client
      .from('chats')
      .select('id')
      .eq('post_id', postId)
      .maybeSingle();
    if (!chat) return 0;
    const { count } = await this.supabase.client
      .from('chat_messages')
      .select('*', { count: 'exact', head: true })
      .eq('chat_id', chat.id as string);
    return count ?? 0;
  }
}
