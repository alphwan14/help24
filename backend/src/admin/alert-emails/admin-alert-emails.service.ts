import {
  BadRequestException,
  HttpException,
  HttpStatus,
  Injectable,
  Logger,
  OnModuleDestroy,
  OnModuleInit,
  ServiceUnavailableException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash } from 'crypto';
import { PeriodicTask } from '../../common/periodic-task';
import { SupabaseService } from '../../supabase/supabase.service';
import { MailNotSentError, SupportMailerService } from '../../support/support-mailer.service';
import { AdminContext } from '../auth/admin-role';
import { AdminAlertsService } from '../alerts/admin-alerts.service';
import { AdminAlert, AlertCategory } from '../alerts/alert-rules';
import {
  ALERTS_FROM,
  ALERT_EMAIL_CATEGORIES,
  ALERT_EMAIL_FREQUENCIES,
  AlertEmailContent,
  AlertEmailFrequency,
  AlertEmailSettings,
  AlertSeen,
  alertEmail,
  digestDue,
  forAdmin,
  nairobiClock,
  newAlerts,
  readSettings,
  testEmail,
} from './alert-email-rules';

type Row = Record<string, any>;

/** Every five minutes: soon enough to act on, rare enough to stay quiet. */
const SWEEP_INTERVAL_MS = 5 * 60_000;
/** One test email per admin per minute. */
const TEST_GAP_MS = 60_000;

const SETTINGS = 'admin_alert_email_settings';
const STATE = 'admin_alert_email_state';

/** Postgres / PostgREST "no such table": migration 141 not applied yet. */
function isMissingTable(error: { code?: string } | null | undefined): boolean {
  return error?.code === '42P01' || error?.code === 'PGRST205';
}

export interface AlertEmailSettingsView extends AlertEmailSettings {
  /** Where the emails go: the admin's own console address. */
  email: string;
  /** False until migration 141 is applied and email sending is set up. */
  available: boolean;
}

/**
 * Emails admins about what needs them, so nobody has to sign in to find out.
 *
 * A self-scheduled sweep (PeriodicTask, like the dispute SLA sweep) reads the
 * same alert list the console shows (AdminAlertsService), works out what is
 * new since the last sweep (admin_alert_email_state, migration 141), and sends
 * each admin one email covering the kinds they chose. Admins who chose the
 * morning summary get one email a day from 08:00 Nairobi time instead.
 *
 * Never blocks anything: no Resend key, no tables yet, or an alert source that
 * cannot be read, and the sweep does less, quietly. Set ADMIN_ALERT_EMAILS=off
 * to stop it entirely.
 */
@Injectable()
export class AdminAlertEmailsService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(AdminAlertEmailsService.name);
  private readonly task = new PeriodicTask('ALERT-EMAILS', this.logger);
  private missingTablesLogged = false;
  private readonly lastTest = new Map<string, number>();

  constructor(
    private readonly supabase: SupabaseService,
    private readonly alerts: AdminAlertsService,
    private readonly mailer: SupportMailerService,
    private readonly config: ConfigService,
  ) {}

  private get db() {
    return this.supabase.client;
  }

  onModuleInit(): void {
    if ((this.config.get<string>('ADMIN_ALERT_EMAILS') ?? '').trim().toLowerCase() === 'off') {
      this.logger.log('[ALERT-EMAILS] off (ADMIN_ALERT_EMAILS=off)');
      return;
    }
    this.task.start(async () => {
      await this.sweep();
    }, SWEEP_INTERVAL_MS);
    this.logger.log('[ALERT-EMAILS] started — every 5m, morning summary from 08:00 Nairobi');
  }

  async onModuleDestroy(): Promise<void> {
    await this.task.stop();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // The sweep
  // ═══════════════════════════════════════════════════════════════════════════

  /** One pass. Public so tests (and an operator) can run it directly. */
  async sweep(now = new Date()): Promise<{ sent: number; skipped?: string }> {
    if (!this.mailer.configured) return { sent: 0, skipped: 'Email sending is not set up.' };

    const { data: seenRows, error: seenError } = await this.db.from(STATE).select('alert_id, latest_at, item_count');
    if (seenError) {
      if (isMissingTable(seenError)) {
        if (!this.missingTablesLogged) this.logger.warn('[ALERT-EMAILS] waiting for migration 141 (admin_alert_email_*).');
        this.missingTablesLogged = true;
        return { sent: 0, skipped: 'Migration 141 is not applied.' };
      }
      this.logger.warn(`[ALERT-EMAILS] could not read what was sent before: ${seenError.message}`);
      return { sent: 0, skipped: 'State unreadable.' };
    }
    const seen = new Map(((seenRows ?? []) as AlertSeen[]).map((r) => [r.alert_id, r]));

    const [{ data: admins, error: adminsError }, { data: settingsRows, error: settingsError }] = await Promise.all([
      this.db.from('admin_users').select('id, email, active').eq('active', true),
      this.db.from(SETTINGS).select('admin_id, frequency, categories, last_digest_on'),
    ]);
    if (adminsError || settingsError) {
      this.logger.warn(`[ALERT-EMAILS] could not read admins: ${(adminsError ?? settingsError)?.message}`);
      return { sent: 0, skipped: 'Admins unreadable.' };
    }
    const settingsBy = new Map(((settingsRows ?? []) as Row[]).map((r) => [r.admin_id as string, r]));

    const result = await this.alerts.list();
    const open = result.alerts.filter((a) => !a.review);
    const fresh = newAlerts(open, seen);
    const today = nairobiClock(now).date;

    let sent = 0;
    for (const admin of (admins ?? []) as Row[]) {
      const email = typeof admin.email === 'string' ? admin.email.trim() : '';
      if (!email.includes('@')) continue;
      const row = settingsBy.get(admin.id as string);
      const settings = readSettings(row);

      if (settings.frequency === 'instant') {
        const mine = forAdmin(fresh, settings);
        if (mine.length && (await this.deliver(admin.id as string, email, alertEmail('new', mine), keyFor('new', admin.id, mine)))) sent += 1;
      } else if (settings.frequency === 'daily' && digestDue(now, (row?.last_digest_on as string | null) ?? null)) {
        const mine = forAdmin(open, settings);
        if (mine.length && (await this.deliver(admin.id as string, email, alertEmail('digest', mine), `alerts-digest-${admin.id}-${today}`))) sent += 1;
        // Marked done even when nothing was waiting: one summary a day at most.
        await this.db.from(SETTINGS).update({ last_digest_on: today }).eq('admin_id', admin.id);
      }
    }

    await this.remember(result.alerts, seen, result.unavailable.length > 0);
    return { sent };
  }

  /**
   * Record what each alert covers now. An alert that has cleared is
   * forgotten, so it is announced again if it comes back, unless a source
   * could not be read this time, when its absence proves nothing.
   */
  private async remember(alerts: AdminAlert[], seen: Map<string, AlertSeen>, partial: boolean): Promise<void> {
    const at = new Date().toISOString();
    if (alerts.length) {
      const { error } = await this.db.from(STATE).upsert(
        alerts.map((a) => ({ alert_id: a.id, latest_at: a.latest_at, item_count: a.count, updated_at: at })),
        { onConflict: 'alert_id' },
      );
      if (error) this.logger.warn(`[ALERT-EMAILS] could not record what was sent: ${error.message}`);
    }
    if (partial) return;
    const current = new Set(alerts.map((a) => a.id as string));
    const gone = [...seen.keys()].filter((id) => !current.has(id));
    if (gone.length) await this.db.from(STATE).delete().in('alert_id', gone);
  }

  private async deliver(adminId: string, to: string, mail: AlertEmailContent, idempotencyKey: string): Promise<boolean> {
    try {
      await this.mailer.send({ from: ALERTS_FROM, to, subject: mail.subject, text: mail.text, html: mail.html, idempotencyKey });
      return true;
    } catch (e) {
      // The admin's id only: an email address never goes into a log line.
      this.logger.warn(`[ALERT-EMAILS] not sent to admin ${adminId}: ${e instanceof Error ? e.message : String(e)}`);
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Each admin's own setting
  // ═══════════════════════════════════════════════════════════════════════════

  async settingsFor(admin: AdminContext): Promise<AlertEmailSettingsView> {
    const { data, error } = await this.db.from(SETTINGS).select('frequency, categories').eq('admin_id', admin.id).maybeSingle();
    if (error && !isMissingTable(error)) throw new ServiceUnavailableException('Could not read your alert settings right now.');
    return { ...readSettings(data), email: admin.email, available: !error && this.mailer.configured };
  }

  async saveSettings(admin: AdminContext, input: { frequency: string; categories: string[] }): Promise<AlertEmailSettingsView> {
    if (!ALERT_EMAIL_FREQUENCIES.includes(input.frequency as AlertEmailFrequency)) throw new BadRequestException('Choose how often.');
    const categories = ALERT_EMAIL_CATEGORIES.filter((c) => input.categories.includes(c));
    if (input.categories.some((c) => !ALERT_EMAIL_CATEGORIES.includes(c as AlertCategory))) throw new BadRequestException('Unknown kind of alert.');
    const { error } = await this.db.from(SETTINGS).upsert(
      // A switch to the morning summary starts tomorrow, not with an email right now.
      {
        admin_id: admin.id,
        frequency: input.frequency,
        categories,
        updated_at: new Date().toISOString(),
        ...(input.frequency === 'daily' ? { last_digest_on: nairobiClock(new Date()).date } : {}),
      },
      { onConflict: 'admin_id' },
    );
    if (error) {
      if (isMissingTable(error)) throw new ServiceUnavailableException('Email alerts are not set up on the server yet.');
      throw new ServiceUnavailableException('Could not save your alert settings right now.');
    }
    return this.settingsFor(admin);
  }

  /** A sample alert to the admin's own address, so they can see it arrives. */
  async sendTest(admin: AdminContext): Promise<{ sent: true; to: string }> {
    const last = this.lastTest.get(admin.id) ?? 0;
    if (Date.now() - last < TEST_GAP_MS) {
      throw new HttpException('A test email just went out. Check your inbox, then try again in a minute.', HttpStatus.TOO_MANY_REQUESTS);
    }
    this.lastTest.set(admin.id, Date.now());
    const mail = testEmail();
    try {
      await this.mailer.send({
        from: ALERTS_FROM,
        to: admin.email,
        subject: mail.subject,
        text: mail.text,
        html: mail.html,
        idempotencyKey: `alerts-test-${admin.id}-${Date.now()}`,
      });
    } catch (e) {
      this.lastTest.delete(admin.id);
      throw new ServiceUnavailableException(e instanceof MailNotSentError ? e.message : 'The test email could not be sent.');
    }
    return { sent: true, to: admin.email };
  }
}

/** Same admin, same alerts, same records: Resend sends it once even if a sweep repeats. */
function keyFor(kind: string, adminId: unknown, alerts: AdminAlert[]): string {
  const basis = alerts.map((a) => `${a.id}:${a.count}:${a.latest_at ?? ''}`).sort().join('|');
  return `alerts-${kind}-${adminId}-${createHash('sha256').update(basis).digest('hex').slice(0, 24)}`;
}
