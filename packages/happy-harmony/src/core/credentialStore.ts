import type { KeyValueStore } from './storage';

const AUTH_KEY = 'auth_credentials';

export interface Credentials {
  token: string;
  secretBase64Url: string;
}

export interface CredentialStore {
  getCredentials(): Promise<Credentials | null>;
  setCredentials(credentials: Credentials): Promise<boolean>;
  removeCredentials(): Promise<boolean>;
}

export function createCredentialStore(storage: KeyValueStore): CredentialStore {
  return {
    async getCredentials() {
      const raw = storage.getString(AUTH_KEY);
      if (!raw) {
        return null;
      }
      try {
        const parsed = JSON.parse(raw) as Credentials;
        if (typeof parsed.token !== 'string' || typeof parsed.secretBase64Url !== 'string') {
          return null;
        }
        return parsed;
      } catch {
        return null;
      }
    },
    async setCredentials(credentials) {
      storage.setString(AUTH_KEY, JSON.stringify(credentials));
      return true;
    },
    async removeCredentials() {
      storage.remove(AUTH_KEY);
      return true;
    },
  };
}
