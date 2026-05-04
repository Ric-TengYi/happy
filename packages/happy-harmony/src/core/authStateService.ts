import type { AuthService } from './authService';
import { decodeBase64Url, encodeBase64Url } from './base64';
import type { CredentialStore, Credentials } from './credentialStore';
import { normalizeSecretKey } from './secretKeyBackup';

const ACCOUNT_SECRET_LENGTH = 32;

export type AuthState =
  | { status: 'unauthenticated' }
  | { status: 'authenticated'; credentials: Credentials };

export interface AuthStateService {
  loadSession(): Promise<AuthState>;
  createAccount(): Promise<Credentials>;
  restoreAccount(secretInput: string): Promise<Credentials>;
  logout(): Promise<void>;
}

export interface AuthStateServiceDependencies {
  credentialStore: CredentialStore;
  authService: AuthService;
  randomBytes(length: number): Uint8Array | Promise<Uint8Array>;
}

export function createAuthStateService(dependencies: AuthStateServiceDependencies): AuthStateService {
  async function saveCredentials(credentials: Credentials): Promise<Credentials> {
    if (credentials.token.length === 0) {
      throw new Error('Auth token is empty');
    }
    const saved = await dependencies.credentialStore.setCredentials(credentials);
    if (!saved) {
      throw new Error('Failed to save credentials');
    }
    return credentials;
  }

  return {
    async loadSession() {
      const credentials = await dependencies.credentialStore.getCredentials();
      return credentials
        ? { status: 'authenticated', credentials }
        : { status: 'unauthenticated' };
    },

    async createAccount() {
      const secret = await dependencies.randomBytes(ACCOUNT_SECRET_LENGTH);
      assertAccountSecret(secret);
      const token = await dependencies.authService.getToken(secret);
      return saveCredentials({
        token,
        secretBase64Url: encodeBase64Url(secret),
      });
    },

    async restoreAccount(secretInput) {
      const normalizedSecret = normalizeSecretKey(secretInput);
      const secret = decodeBase64Url(normalizedSecret);
      assertAccountSecret(secret);
      const token = await dependencies.authService.getToken(secret);
      return saveCredentials({
        token,
        secretBase64Url: encodeBase64Url(secret),
      });
    },

    async logout() {
      const removed = await dependencies.credentialStore.removeCredentials();
      if (!removed) {
        throw new Error('Failed to remove credentials');
      }
    },
  };
}

function assertAccountSecret(secret: Uint8Array): void {
  if (secret.length !== ACCOUNT_SECRET_LENGTH) {
    throw new Error(`Account secret must be ${ACCOUNT_SECRET_LENGTH} bytes`);
  }
}
