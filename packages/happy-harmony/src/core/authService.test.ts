import { describe, expect, it } from 'vitest';
import { createAuthService, parseHappyAuthUrl } from './authService';
import { encodeBase64, encodeBase64Url } from './base64';

describe('AuthService', () => {
  it('builds /v1/auth token requests from a client-generated challenge', async () => {
    const posted: Array<{ url: string; body: unknown; headers: Record<string, string> }> = [];
    const secret = Uint8Array.from(Array.from({ length: 32 }, (_, index) => index));
    const service = createAuthService({
      getServerUrl: () => 'https://47.118.25.177',
      getHappyClientId: () => 'harmony/0.1.0',
      createAuthChallenge: (input) => {
        expect(input).toEqual(secret);
        return {
          publicKey: Uint8Array.from([1, 2, 3]),
          challenge: Uint8Array.from([4, 5, 6]),
          signature: Uint8Array.from([7, 8, 9]),
        };
      },
      postJson: async <T>(url: string, body: unknown, headers: Record<string, string>): Promise<T> => {
        posted.push({ url, body, headers });
        return { token: 'server-token' } as T;
      },
    });

    await expect(service.getToken(secret)).resolves.toBe('server-token');

    expect(posted).toEqual([{
      url: 'https://47.118.25.177/v1/auth',
      body: {
        publicKey: encodeBase64(Uint8Array.from([1, 2, 3])),
        challenge: encodeBase64(Uint8Array.from([4, 5, 6])),
        signature: encodeBase64(Uint8Array.from([7, 8, 9])),
      },
      headers: {
        'X-Happy-Client': 'harmony/0.1.0',
      },
    }]);
  });

  it('parses terminal and account QR URLs with base64url public keys', () => {
    const publicKey = Uint8Array.from(Array.from({ length: 32 }, (_, index) => index));
    const encoded = encodeBase64Url(publicKey);

    expect(parseHappyAuthUrl(`happy://terminal?${encoded}`)).toEqual({
      type: 'terminal',
      publicKey,
    });
    expect(parseHappyAuthUrl(`happy:///account?${encoded}`)).toEqual({
      type: 'account',
      publicKey,
    });
    expect(() => parseHappyAuthUrl('happy://terminal?')).toThrow('Missing auth public key');
    expect(() => parseHappyAuthUrl(`happy://terminal?${encodeBase64Url(Uint8Array.from([1, 2, 3, 4]))}`)).toThrow(
      'Auth public key must be 32 bytes',
    );
  });
});
