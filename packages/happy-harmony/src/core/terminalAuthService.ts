import { parseHappyAuthUrl } from './authService';
import { decodeBase64Url, encodeBase64 } from './base64';
import type { Credentials } from './credentialStore';

const ACCOUNT_SECRET_LENGTH = 32;
const BOX_PUBLIC_KEY_LENGTH = 32;

export type TerminalAuthApprovalResult =
  | { status: 'approved'; supportsV2: boolean }
  | { status: 'already_authorized'; supportsV2: boolean }
  | { status: 'not_found'; supportsV2: boolean };

export interface TerminalAuthService {
  approveTerminalAuthUrl(url: string, credentials: Credentials): Promise<TerminalAuthApprovalResult>;
}

export interface TerminalAuthServiceDependencies {
  getServerUrl(): string;
  getHappyClientId(): string;
  getContentPublicKey(accountSecret: Uint8Array): Uint8Array | Promise<Uint8Array>;
  encryptBox(plaintext: Uint8Array, recipientPublicKey: Uint8Array): Uint8Array | Promise<Uint8Array>;
  getJson<T>(url: string, headers: Record<string, string>): Promise<T>;
  postJson<T>(url: string, body: unknown, headers: Record<string, string>): Promise<T>;
}

interface TerminalAuthRequestStatus {
  status: 'not_found' | 'pending' | 'authorized';
  supportsV2: boolean;
}

export function createTerminalAuthService(dependencies: TerminalAuthServiceDependencies): TerminalAuthService {
  return {
    async approveTerminalAuthUrl(url, credentials) {
      if (credentials.token.length === 0) {
        throw new Error('Auth token is empty');
      }
      const parsed = parseHappyAuthUrl(url.trim());
      if (parsed.type !== 'terminal') {
        throw new Error('Only terminal auth URLs can be approved here');
      }
      assertBoxPublicKey(parsed.publicKey);
      const accountSecret = decodeBase64Url(credentials.secretBase64Url);
      assertAccountSecret(accountSecret);

      const publicKeyBase64 = encodeBase64(parsed.publicKey);
      const status = await dependencies.getJson<TerminalAuthRequestStatus>(
        `${dependencies.getServerUrl()}/v1/auth/request/status?publicKey=${encodeURIComponent(publicKeyBase64)}`,
        {
          'X-Happy-Client': dependencies.getHappyClientId(),
        },
      );

      if (status.status === 'not_found') {
        return { status: 'not_found', supportsV2: status.supportsV2 };
      }
      if (status.status === 'authorized') {
        return { status: 'already_authorized', supportsV2: status.supportsV2 };
      }
      if (status.status !== 'pending') {
        throw new Error('Unsupported terminal auth status');
      }

      const plaintext = status.supportsV2
        ? buildV2Plaintext(await dependencies.getContentPublicKey(accountSecret))
        : accountSecret;
      const response = await dependencies.encryptBox(plaintext, parsed.publicKey);
      await dependencies.postJson(
        `${dependencies.getServerUrl()}/v1/auth/response`,
        {
          publicKey: publicKeyBase64,
          response: encodeBase64(response),
        },
        {
          Authorization: `Bearer ${credentials.token}`,
          'X-Happy-Client': dependencies.getHappyClientId(),
        },
      );
      return { status: 'approved', supportsV2: status.supportsV2 };
    },
  };
}

function buildV2Plaintext(contentPublicKey: Uint8Array): Uint8Array {
  assertBoxPublicKey(contentPublicKey);
  return Uint8Array.from([0, ...contentPublicKey]);
}

function assertAccountSecret(secret: Uint8Array): void {
  if (secret.length !== ACCOUNT_SECRET_LENGTH) {
    throw new Error(`Account secret must be ${ACCOUNT_SECRET_LENGTH} bytes`);
  }
}

function assertBoxPublicKey(publicKey: Uint8Array): void {
  if (publicKey.length !== BOX_PUBLIC_KEY_LENGTH) {
    throw new Error(`Box public key must be ${BOX_PUBLIC_KEY_LENGTH} bytes`);
  }
}
