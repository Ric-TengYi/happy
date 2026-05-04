import { decodeBase64Url, encodeBase64 } from './base64';

export interface AuthChallenge {
  publicKey: Uint8Array;
  challenge: Uint8Array;
  signature: Uint8Array;
}

export interface AuthService {
  getToken(secret: Uint8Array): Promise<string>;
}

export interface AuthServiceDependencies {
  getServerUrl(): string;
  getHappyClientId(): string;
  createAuthChallenge(secret: Uint8Array): AuthChallenge;
  postJson<T>(url: string, body: unknown, headers: Record<string, string>): Promise<T>;
}

export function createAuthService(dependencies: AuthServiceDependencies): AuthService {
  return {
    async getToken(secret) {
      const challenge = dependencies.createAuthChallenge(secret);
      const response = await dependencies.postJson<{ token: string }>(
        `${dependencies.getServerUrl()}/v1/auth`,
        {
          publicKey: encodeBase64(challenge.publicKey),
          challenge: encodeBase64(challenge.challenge),
          signature: encodeBase64(challenge.signature),
        },
        {
          'X-Happy-Client': dependencies.getHappyClientId(),
        },
      );
      return response.token;
    },
  };
}

export function parseHappyAuthUrl(url: string): {
  type: 'terminal' | 'account';
  publicKey: Uint8Array;
} {
  if (url.startsWith('happy://terminal?')) {
    return {
      type: 'terminal',
      publicKey: parsePublicKeyTail(url.slice('happy://terminal?'.length)),
    };
  }
  if (url.startsWith('happy:///account?')) {
    return {
      type: 'account',
      publicKey: parsePublicKeyTail(url.slice('happy:///account?'.length)),
    };
  }
  throw new Error('Unsupported Happy auth URL');
}

function parsePublicKeyTail(tail: string): Uint8Array {
  if (!tail) {
    throw new Error('Missing auth public key');
  }
  const publicKey = decodeBase64Url(tail);
  if (publicKey.length !== 32) {
    throw new Error('Auth public key must be 32 bytes');
  }
  return publicKey;
}
