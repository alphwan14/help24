/**
 * Auto-approval policy for a completed job (migration 134).
 *
 * When a provider marks a job done, the client has a window to approve or
 * dispute. If they do neither, the completion approves itself and the
 * provider is paid through the same path as the client's own Approve.
 *
 * Owner decision 2026-11-04: 48 hours, reminders at 24 h and 44 h. The two
 * reminders are expressed as "halfway" and "4 hours before the end", so a
 * different window keeps the same shape — 24 h gives 12 h and 20 h, which is
 * the schedule first proposed.
 *
 * Pure: no I/O, no clock of its own. CompletionAutoApprovalService supplies
 * `now`, which is what makes every rule here testable to the second.
 */

const HOUR_MS = 3_600_000;
const DEFAULT_HOURS = 48;
/** Below this the final reminder would land before the first one. */
const MIN_HOURS = 12;
const MAX_HOURS = 24 * 14;
const FINAL_REMINDER_BEFORE_HOURS = 4;

/** The window, from AUTO_APPROVE_HOURS; out-of-range values fall back to 48. */
export function autoApproveHours(raw: string | undefined = process.env.AUTO_APPROVE_HOURS): number {
  const hours = Number(raw);
  return Number.isFinite(hours) && hours >= MIN_HOURS && hours <= MAX_HOURS ? hours : DEFAULT_HOURS;
}

/** AUTO_APPROVE_ENABLED=false stops the sweep (deadlines are still stamped). */
export function autoApproveEnabled(raw: string | undefined = process.env.AUTO_APPROVE_ENABLED): boolean {
  return raw?.trim().toLowerCase() !== 'false';
}

/** The deadline a new completion gets. */
export function autoApproveDeadline(createdAt: Date, hours = autoApproveHours()): Date {
  return new Date(createdAt.getTime() + hours * HOUR_MS);
}

export interface PendingCompletionClock {
  created_at: string;
  auto_approve_at: string | null;
  first_reminder_sent_at: string | null;
  final_reminder_sent_at: string | null;
}

export type DueAction = 'approve' | 'final_reminder' | 'first_reminder' | null;

/**
 * What the sweep owes this completion right now — at most ONE thing.
 *
 * Approval outranks reminders: a sweep that was down for a day approves an
 * overdue job rather than sending two stale reminders first. A reminder that
 * was skipped that way is not sent afterwards — the job is already approved.
 * The final reminder likewise supersedes an unsent first one. Rows with no
 * deadline (created before migration 134) are never acted on.
 */
export function dueAction(row: PendingCompletionClock, now: Date): DueAction {
  if (!row.auto_approve_at) return null;
  const deadline = new Date(row.auto_approve_at).getTime();
  const created = new Date(row.created_at).getTime();
  const t = now.getTime();
  if (!Number.isFinite(deadline) || !Number.isFinite(created)) return null;

  if (t >= deadline) return 'approve';
  if (!row.final_reminder_sent_at && t >= deadline - FINAL_REMINDER_BEFORE_HOURS * HOUR_MS) {
    return 'final_reminder';
  }
  if (!row.first_reminder_sent_at && !row.final_reminder_sent_at && t >= created + (deadline - created) / 2) {
    return 'first_reminder';
  }
  return null;
}

/** "Tue 5 Nov, 14:05" in Kenya time — what a reminder tells the client. */
export function kenyaTime(iso: string): string {
  return new Intl.DateTimeFormat('en-KE', {
    timeZone: 'Africa/Nairobi',
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(new Date(iso));
}
