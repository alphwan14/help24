import { Response } from 'express';
import { AppConfigController } from './app-config.controller';
import { AppConfigService } from './app-config.service';
import { AppConfigAdminController } from './app-config-admin.controller';
import { DEFAULT_CLIENT_CONFIG } from './client-config';

/** Captures the headers/status the controller sets. */
function fakeResponse() {
  const headers: Record<string, string> = {};
  let status = 200;
  const res = {
    setHeader: (name: string, value: string) => {
      headers[name] = value;
    },
    status: (code: number) => {
      status = code;
      return res;
    },
  } as unknown as Response;
  return { res, headers, statusOf: () => status };
}

function fakeService(version = 'abc123'): AppConfigService {
  return {
    clientConfig: async () => ({ version, config: DEFAULT_CLIENT_CONFIG }),
    isClientKey: (key: string) => key === 'ops.maintenance',
    adminUpdate: async () => undefined,
    adminSet: async () => ({ recorded: true }),
  } as unknown as AppConfigService;
}

describe('AppConfigController — GET /config', () => {
  it('returns the versioned config with an ETag', async () => {
    const controller = new AppConfigController(fakeService());
    const { res, headers } = fakeResponse();

    const body = await controller.getConfig(res);

    expect(body).toEqual({ version: 'abc123', config: DEFAULT_CLIENT_CONFIG });
    expect(headers['ETag']).toBe('"abc123"');
    expect(headers['Cache-Control']).toContain('max-age=60');
  });

  it('answers 304 with no body when the client already has this version', async () => {
    const controller = new AppConfigController(fakeService());
    const { res, statusOf } = fakeResponse();

    const body = await controller.getConfig(res, '"abc123"');

    expect(body).toBeUndefined();
    expect(statusOf()).toBe(304);
  });

  it('returns a full body when the client holds a stale version', async () => {
    const controller = new AppConfigController(fakeService('new-version'));
    const { res, statusOf } = fakeResponse();

    const body = await controller.getConfig(res, '"old-version"');

    expect(statusOf()).toBe(200);
    expect(body).toMatchObject({ version: 'new-version' });
  });

  it('ignores platform/app_version — every client gets the same document in Phase 1', async () => {
    const controller = new AppConfigController(fakeService());
    const { res } = fakeResponse();

    const android = await controller.getConfig(res, undefined, 'android', '1.0.0');
    const ios = await controller.getConfig(res, undefined, 'ios', '9.9.9');

    expect(android).toEqual(ios);
  });
});

describe('AppConfigAdminController', () => {
  const admin = { id: 'a-1', email: 'ops@example.test', name: 'Ops', role: 'senior_admin' as const };
  const reason = 'Raising the gate after 1.0.5 shipped';

  it('rejects a key outside the client contract', async () => {
    const controller = new AppConfigAdminController(fakeService());
    await expect(controller.updateConfig('feed.weights', { value: { distance: 1 }, reason }, admin)).rejects.toThrow(
      /Unknown config key/,
    );
  });

  it('rejects a non-object value', async () => {
    const controller = new AppConfigAdminController(fakeService());
    await expect(controller.updateConfig('ops.maintenance', { value: [], reason }, admin)).rejects.toThrow(
      /must be a JSON object/,
    );
  });

  it('refuses a change without a reason', async () => {
    const controller = new AppConfigAdminController(fakeService());
    await expect(controller.updateConfig('ops.maintenance', { value: { active: true } }, admin)).rejects.toThrow(
      /reason/,
    );
    await expect(
      controller.updateConfig('ops.maintenance', { value: { active: true }, reason: ' ok ' }, admin),
    ).rejects.toThrow(/reason/);
  });

  it('refuses a version gate the app could not compare', async () => {
    const service = fakeService();
    (service as unknown as { isClientKey: (k: string) => boolean }).isClientKey = () => true;
    const controller = new AppConfigAdminController(service);
    await expect(
      controller.updateConfig('ops.min_version', { value: { hard: '1.0', soft: '' }, reason }, admin),
    ).rejects.toThrow(/min_version.hard/);
    await expect(
      controller.updateConfig('ops.min_version', { value: { soft: 'v1.0.5' }, reason }, admin),
    ).rejects.toThrow(/min_version.soft/);
  });

  describe('the in-app update download (apk_url, sha256, size_bytes)', () => {
    const SHA = 'EAE851787E4DDD249294F1CDBD1D738B598FD0D64EB8A0FAC1740AE4FC1CDF9F';
    const URL = 'https://github.com/alphwan14/help24/releases/download/v1.0.13/app-release.apk';
    const setup = () => {
      const saved: Array<Record<string, unknown>> = [];
      const service = fakeService();
      (service as unknown as { isClientKey: (k: string) => boolean }).isClientKey = () => true;
      (service as unknown as { adminSet: (...a: unknown[]) => Promise<{ recorded: boolean }> }).adminSet = async (
        ...a: unknown[]
      ) => {
        saved.push(a[2] as Record<string, unknown>);
        return { recorded: true };
      };
      return { controller: new AppConfigAdminController(service), saved };
    };

    it('saves all three together, trimmed, the checksum in lowercase', async () => {
      const { controller, saved } = setup();
      await controller.updateConfig(
        'ops.min_version',
        { value: { soft: '1.0.13', hard: '', apk_url: ` ${URL} `, sha256: SHA, size_bytes: 85_000_000 }, reason },
        admin,
      );
      expect(saved[0]).toMatchObject({ apk_url: URL, sha256: SHA.toLowerCase(), size_bytes: 85_000_000 });
    });

    it('allows none of them: the Update button then opens the download page', async () => {
      const { controller, saved } = setup();
      await controller.updateConfig(
        'ops.min_version',
        { value: { soft: '1.0.13', apk_url: '', sha256: '', size_bytes: 0 }, reason },
        admin,
      );
      expect(saved).toHaveLength(1);
    });

    it('refuses a partial set, a foreign or plain-http link, a bad checksum or size', async () => {
      const { controller, saved } = setup();
      const bad = [
        { apk_url: URL, sha256: '', size_bytes: 0 },
        { apk_url: '', sha256: SHA, size_bytes: 85_000_000 },
        { apk_url: 'https://evil.example/app-release.apk', sha256: SHA, size_bytes: 85_000_000 },
        { apk_url: URL.replace('https:', 'http:'), sha256: SHA, size_bytes: 85_000_000 },
        { apk_url: 'https://github.com/someone/else/releases/download/v1/app.apk', sha256: SHA, size_bytes: 85_000_000 },
        { apk_url: URL, sha256: 'abc123', size_bytes: 85_000_000 },
        { apk_url: URL, sha256: SHA, size_bytes: 500 },
        { apk_url: URL, sha256: SHA, size_bytes: 85.5 },
      ];
      for (const value of bad) {
        await expect(controller.updateConfig('ops.min_version', { value, reason }, admin)).rejects.toThrow(/min_version/);
      }
      expect(saved).toHaveLength(0);
    });
  });

  it('records the change with the admin and reason, and returns the merged result', async () => {
    const calls: unknown[][] = [];
    const service = fakeService();
    (service as unknown as { adminSet: (...a: unknown[]) => Promise<{ recorded: boolean }> }).adminSet = async (
      ...a: unknown[]
    ) => {
      calls.push(a);
      return { recorded: true };
    };
    const controller = new AppConfigAdminController(service);
    const result = await controller.updateConfig('ops.maintenance', { value: { active: true }, reason: `  ${reason} ` }, admin);
    expect(result).toMatchObject({ version: 'abc123', recorded: true });
    expect(calls).toEqual([[admin, 'ops.maintenance', { active: true }, reason]]);
  });
});
