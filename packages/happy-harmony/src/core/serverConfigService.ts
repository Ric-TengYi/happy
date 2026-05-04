import type { KeyValueStore } from './storage';

const SERVER_KEY = 'custom-server-url';
const DEFAULT_SERVER_URL = 'https://47.118.25.177';
const HAPPY_SERVER_MARKER = 'Welcome to Happy Server!';

export interface HttpGetText {
  (url: string): Promise<{ ok: boolean; text: string }>;
}

export interface ServerConfigService {
  getServerUrl(): string;
  setServerUrl(url: string | null): void;
  validateUrl(url: string): { valid: boolean; error?: string };
  validateServer(url: string): Promise<boolean>;
  isUsingCustomServer(): boolean;
}

export function createServerConfigService(options: {
  storage: KeyValueStore;
  httpGetText?: HttpGetText;
  defaultServerUrl?: string;
}): ServerConfigService {
  const defaultServerUrl = options.defaultServerUrl ?? DEFAULT_SERVER_URL;
  const httpGetText = options.httpGetText ?? defaultHttpGetText;

  return {
    getServerUrl() {
      return options.storage.getString(SERVER_KEY) ?? defaultServerUrl;
    },
    setServerUrl(url) {
      const trimmed = url?.trim();
      if (trimmed) {
        options.storage.setString(SERVER_KEY, trimmed);
      } else {
        options.storage.remove(SERVER_KEY);
      }
    },
    validateUrl(url) {
      if (!url.trim()) {
        return { valid: false, error: '请输入服务器地址' };
      }
      try {
        const parsed = new URL(url);
        if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
          return { valid: false, error: '服务器地址必须以 http:// 或 https:// 开头' };
        }
        return { valid: true };
      } catch {
        return { valid: false, error: '服务器地址格式不正确' };
      }
    },
    async validateServer(url) {
      try {
        const response = await httpGetText(url);
        return response.ok && response.text.includes(HAPPY_SERVER_MARKER);
      } catch {
        return false;
      }
    },
    isUsingCustomServer() {
      return this.getServerUrl() !== defaultServerUrl;
    },
  };
}

async function defaultHttpGetText(url: string): Promise<{ ok: boolean; text: string }> {
  const response = await fetch(url, {
    method: 'GET',
    headers: {
      Accept: 'text/plain',
    },
  });
  return {
    ok: response.ok,
    text: await response.text(),
  };
}
