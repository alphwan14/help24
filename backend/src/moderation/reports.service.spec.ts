import { Logger } from '@nestjs/common';
import { NotificationsService } from '../notifications/notifications.service';
import { CreateReportDto } from './dto/report.dto';
import { Answer, fakeSupabase } from './fake-supabase.testspec';
import { ReportsService } from './reports.service';

const REPORT_ID = '7f3a9c21-0b2d-4e5f-8a9b-0c1d2e3f4a5b';

function build(answer: Answer = { data: { id: REPORT_ID } }) {
  const { supabase, calls } = fakeSupabase(() => answer);
  const notifications = { send: jest.fn().mockResolvedValue(undefined) };
  const service = new ReportsService(supabase, notifications as unknown as NotificationsService);
  return { service, calls, notifications };
}

const dto = (over: Partial<CreateReportDto> = {}): CreateReportDto =>
  Object.assign(new CreateReportDto(), {
    reporter_id: 'u_alice',
    target_type: 'post',
    target_id: 'b1f1f1f1-0000-4000-8000-000000000001',
    category: 'scam_or_fraud',
    details: '  Asked me to pay outside the app  ',
    ...over,
  });

beforeEach(() => {
  jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
});
afterEach(() => jest.restoreAllMocks());

describe('ReportsService.create', () => {
  it('1/2: files a listing report on the API door with the verified reporter', async () => {
    const { service, calls } = build();
    await expect(service.create(dto())).resolves.toEqual({ status: 'received', reference: '7F3A9C21' });
    const insert = calls[0].ops.find(([op]) => op === 'insert')?.[1][0] as Record<string, unknown>;
    expect(calls[0].table).toBe('user_reports');
    expect(insert).toMatchObject({
      reporter_id: 'u_alice',
      target_type: 'post',
      reason: 'scam_or_fraud',
      details: 'Asked me to pay outside the app',
      source: 'api',
    });
  });

  it('never lets a client choose the reported person, status or severity', async () => {
    const { service, calls } = build();
    await service.create(dto());
    const insert = calls[0].ops.find(([op]) => op === 'insert')?.[1][0] as Record<string, unknown>;
    for (const field of ['reported_user_id', 'status', 'severity', 'assigned_admin_id', 'resolution']) {
      expect(insert).not.toHaveProperty(field);
    }
  });

  it('keeps chat/listing context only when reporting a PERSON', async () => {
    const chat = 'c1c1c1c1-0000-4000-8000-000000000001';
    const post = 'b1f1f1f1-0000-4000-8000-000000000009';

    const person = build();
    await person.service.create(dto({ target_type: 'user', target_id: 'u_bob', category: 'harassment', chat_id: chat, post_id: post }));
    expect(person.calls[0].ops.find(([op]) => op === 'insert')?.[1][0]).toMatchObject({ chat_id: chat, post_id: post });

    const message = build();
    await message.service.create(dto({ target_type: 'message', category: 'threats', chat_id: chat, post_id: post }));
    expect(message.calls[0].ops.find(([op]) => op === 'insert')?.[1][0]).toMatchObject({ chat_id: null, post_id: null });
  });

  it('passes screenshots through as issued', async () => {
    const { service, calls } = build();
    const path = 'reports/u_alice/0f0f0f0f-0000-4000-8000-000000000001.jpg';
    await service.create(dto({ evidence: [{ path, mime_type: 'image/jpeg', size_bytes: 1234 }] }));
    expect((calls[0].ops.find(([op]) => op === 'insert')?.[1][0] as Record<string, unknown>).evidence).toEqual([
      { path, mime_type: 'image/jpeg', size_bytes: 1234 },
    ]);
  });

  it('23: confirms receipt to the reporter WITHOUT naming the target', async () => {
    const { service, notifications } = build();
    await service.create(dto());
    await new Promise((r) => setImmediate(r));
    expect(notifications.send).toHaveBeenCalledWith({
      userId: 'u_alice',
      type: 'report_received',
      title: 'Report received',
      body: 'Thanks for letting us know. Our team will review your report.',
      data: {},
    });
  });

  it('17: a repeat is acknowledged, not an error — both database forms', async () => {
    for (const error of [
      { code: 'P0001', message: 'HELP24_REPORT_DUPLICATE: you have already reported this' },
      { code: '23505', message: 'duplicate key value violates unique constraint "user_reports_one_open_per_target"' },
    ]) {
      const { service, notifications } = build({ error });
      await expect(service.create(dto())).resolves.toEqual({ status: 'already_reported', reference: null });
      expect(notifications.send).not.toHaveBeenCalled();
    }
  });

  it.each([
    ['HELP24_REPORT_SELF: you cannot report yourself', 400, 'REPORT_SELF'],
    ['HELP24_REPORT_LIMIT: too many reports today', 429, 'REPORT_LIMIT'],
    ['HELP24_REPORT_NOT_PARTICIPANT: you can only report messages in your own conversations', 403, 'REPORT_NOT_PARTICIPANT'],
    ['HELP24_REPORT_INVALID_CATEGORY: threats does not apply to a post', 400, 'REPORT_INVALID_CATEGORY'],
    ['HELP24_REPORT_INVALID_TARGET: listing not found', 400, 'REPORT_INVALID_TARGET'],
  ])('maps "%s" to %i', async (message, status, code) => {
    const { service } = build({ error: { code: 'P0001', message } });
    const error = await service.create(dto()).catch((e: unknown) => e);
    expect(error).toMatchObject({ status });
    expect((error as { getResponse(): { code: string } }).getResponse().code).toBe(code);
  });

  it('an infrastructure fault is a 503, never a success', async () => {
    const { service } = build({ error: { code: '08006', message: 'connection failure' } });
    await expect(service.create(dto())).rejects.toMatchObject({ status: 503 });
  });

  it('refuses without a reporter (the guard binds one for any signed-in caller)', async () => {
    const { service } = build();
    await expect(service.create(dto({ reporter_id: undefined }))).rejects.toMatchObject({ status: 400 });
  });
});
