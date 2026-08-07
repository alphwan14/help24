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
  it('rejects a key outside the client contract', async () => {
    const controller = new AppConfigAdminController(fakeService());
    await expect(controller.updateConfig('feed.weights', { distance: 1 })).rejects.toThrow(
      /Unknown config key/,
    );
  });

  it('rejects a non-object value', async () => {
    const controller = new AppConfigAdminController(fakeService());
    await expect(
      controller.updateConfig('ops.maintenance', [] as unknown as Record<string, unknown>),
    ).rejects.toThrow(/must be a JSON object/);
  });

  it('accepts a valid document and returns the merged result', async () => {
    const controller = new AppConfigAdminController(fakeService());
    const result = await controller.updateConfig('ops.maintenance', { active: true });
    expect(result).toMatchObject({ version: 'abc123' });
  });
});
