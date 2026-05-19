import { describe, expect, it } from 'vitest';
import nacl from 'tweetnacl';
import { createHmac } from 'node:crypto';
import { decodeBase64, decodeBase64Url, encodeBase64, encodeBase64Url } from './base64';
import { boxPublicKeyFromSeed, decryptBoxBundleForTest, encryptBox } from './boxEncryption';
import { deriveKey } from './cryptoLayout';
import { createTerminalAuthService } from './terminalAuthService';

function hmacSha512(key: Uint8Array, data: Uint8Array): Uint8Array {
  const hmac = createHmac('sha512', key);
  hmac.update(data);
  return new Uint8Array(hmac.digest());
}

describe('TerminalAuthService', () => {
  const accountSecret = Uint8Array.from(Array.from({ length: 32 }, (_, index) => index));
  const credentials = {
    token: 'account-token',
    secretBase64Url: encodeBase64Url(accountSecret),
  };
  const terminalSecretKey = Uint8Array.from(Array.from({ length: 32 }, (_, index) => 200 - index));
  const terminalPublicKey = nacl.box.keyPair.fromSecretKey(terminalSecretKey).publicKey;
  const terminalUrl = `happy://terminal?${encodeBase64Url(terminalPublicKey)}`;

  it('approves pending terminal requests with a v1 encrypted account secret', async () => {
    const requests: Array<{ method: string; url: string; body?: unknown; headers: Record<string, string> }> = [];
    const service = createTerminalAuthService({
      getServerUrl: () => 'https://api.cluster-fluster.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getContentPublicKey: async () => {
        throw new Error('V2 should not be derived');
      },
      encryptBox,
      getJson: async <T>(url: string, headers: Record<string, string>): Promise<T> => {
        requests.push({ method: 'GET', url, headers });
        return { status: 'pending', supportsV2: false } as T;
      },
      postJson: async <T>(url: string, body: unknown, headers: Record<string, string>): Promise<T> => {
        requests.push({ method: 'POST', url, body, headers });
        return { success: true } as T;
      },
    });

    await expect(service.approveTerminalAuthUrl(terminalUrl, credentials)).resolves.toEqual({
      status: 'approved',
      supportsV2: false,
    });

    expect(requests[0]).toEqual({
      method: 'GET',
      url: `https://api.cluster-fluster.com/v1/auth/request/status?publicKey=${encodeURIComponent(encodeBase64(terminalPublicKey))}`,
      headers: {
        'X-Happy-Client': 'harmony/0.1.0',
      },
    });
    expect(requests[1].url).toBe('https://api.cluster-fluster.com/v1/auth/response');
    expect(requests[1].headers).toEqual({
      Authorization: 'Bearer account-token',
      'X-Happy-Client': 'harmony/0.1.0',
    });
    const body = requests[1].body as { publicKey: string; response: string };
    expect(body.publicKey).toBe(encodeBase64(terminalPublicKey));
    expect(decryptBoxBundleForTest(decodeBase64(body.response), terminalSecretKey)).toEqual(accountSecret);
  });

  it('approves pending terminal requests with a v2 encrypted content public key', async () => {
    let encryptedPlaintext: Uint8Array | null = null;
    const contentSeed = await deriveKey(accountSecret, 'Happy EnCoder', ['content'], hmacSha512);
    const contentPublicKey = boxPublicKeyFromSeed(contentSeed);
    const service = createTerminalAuthService({
      getServerUrl: () => 'https://api.cluster-fluster.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getContentPublicKey: async (secret) => {
        expect(secret).toEqual(accountSecret);
        return contentPublicKey;
      },
      encryptBox: async (plaintext, publicKey) => {
        expect(publicKey).toEqual(terminalPublicKey);
        encryptedPlaintext = plaintext;
        return Uint8Array.from([1, 2, 3]);
      },
      getJson: async <T>(): Promise<T> => ({ status: 'pending', supportsV2: true }) as T,
      postJson: async <T>(url: string, body: unknown): Promise<T> => {
        expect(url).toBe('https://api.cluster-fluster.com/v1/auth/response');
        expect(body).toEqual({
          publicKey: encodeBase64(terminalPublicKey),
          response: encodeBase64(Uint8Array.from([1, 2, 3])),
        });
        return { success: true } as T;
      },
    });

    await expect(service.approveTerminalAuthUrl(terminalUrl, credentials)).resolves.toEqual({
      status: 'approved',
      supportsV2: true,
    });

    expect(encryptedPlaintext).toEqual(Uint8Array.from([0, ...contentPublicKey]));
  });

  it('does not POST for already resolved terminal requests', async () => {
    const service = createTerminalAuthService({
      getServerUrl: () => 'https://api.cluster-fluster.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getContentPublicKey: async () => Uint8Array.from([]),
      encryptBox,
      getJson: async <T>(): Promise<T> => ({ status: 'authorized', supportsV2: false }) as T,
      postJson: async () => {
        throw new Error('POST should not be called');
      },
    });

    await expect(service.approveTerminalAuthUrl(terminalUrl, credentials)).resolves.toEqual({
      status: 'already_authorized',
      supportsV2: false,
    });
  });

  it('rejects unsupported QR URLs and malformed credentials', async () => {
    const service = createTerminalAuthService({
      getServerUrl: () => 'https://api.cluster-fluster.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getContentPublicKey: async () => Uint8Array.from([]),
      encryptBox,
      getJson: async <T>(): Promise<T> => ({ status: 'pending', supportsV2: false }) as T,
      postJson: async <T>(): Promise<T> => ({ success: true }) as T,
    });

    expect(decodeBase64Url(credentials.secretBase64Url)).toEqual(accountSecret);
    await expect(service.approveTerminalAuthUrl(`happy:///account?${encodeBase64Url(terminalPublicKey)}`, credentials)).rejects.toThrow(
      'Only terminal auth URLs can be approved here',
    );
    await expect(service.approveTerminalAuthUrl(terminalUrl, { token: '', secretBase64Url: credentials.secretBase64Url })).rejects.toThrow(
      'Auth token is empty',
    );
    await expect(service.approveTerminalAuthUrl(terminalUrl, { token: 'token', secretBase64Url: encodeBase64Url(Uint8Array.from([1, 2, 3])) })).rejects.toThrow(
      'Account secret must be 32 bytes',
    );
  });
});
