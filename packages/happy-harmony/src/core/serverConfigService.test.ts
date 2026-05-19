import { describe, expect, it } from 'vitest';
import { createMemoryKeyValueStore } from './storage';
import { createServerConfigService } from './serverConfigService';

describe('ServerConfigService', () => {
  it('defaults to the deployed Happy server and persists custom URL across instances', () => {
    const storage = createMemoryKeyValueStore();
    const service = createServerConfigService({ storage });

    expect(service.getServerUrl()).toBe('https://47.118.25.177');

    service.setServerUrl(' https://example.com/happy ');

    expect(createServerConfigService({ storage }).getServerUrl()).toBe('https://example.com/happy');
  });

  it('accepts only http and https URLs', () => {
    const service = createServerConfigService({ storage: createMemoryKeyValueStore() });

    expect(service.validateUrl('https://47.118.25.177')).toEqual({ valid: true });
    expect(service.validateUrl('http://127.0.0.1:3005')).toEqual({ valid: true });
    expect(service.validateUrl('   ')).toEqual({
      valid: false,
      error: '请输入服务器地址',
    });
    expect(service.validateUrl('happy-server')).toEqual({
      valid: false,
      error: '服务器地址格式不正确',
    });
    expect(service.validateUrl('ftp://47.118.25.177')).toEqual({
      valid: false,
      error: '服务器地址必须以 http:// 或 https:// 开头',
    });
  });

  it('validates Happy server root response text', async () => {
    const service = createServerConfigService({
      storage: createMemoryKeyValueStore(),
      httpGetText: async (url) => {
        expect(url).toBe('https://47.118.25.177');
        return { ok: true, text: 'Welcome to Happy Server!' };
      },
    });

    await expect(service.validateServer('https://47.118.25.177')).resolves.toBe(true);
  });

  it('treats the old public default as the current default server', () => {
    const storage = createMemoryKeyValueStore();
    storage.setString('custom-server-url', 'https://api.cluster-fluster.com');
    const service = createServerConfigService({ storage });

    expect(service.getServerUrl()).toBe('https://47.118.25.177');

    service.setServerUrl('https://api.cluster-fluster.com');

    expect(service.isUsingCustomServer()).toBe(false);
  });
});
