import { describe, expect, it, vi } from 'vitest';
import { createAuthStateService } from './authStateService';
import { createCredentialStore } from './credentialStore';
import { encodeBase64Url } from './base64';
import { formatSecretKeyForBackup } from './secretKeyBackup';
import { createMemoryKeyValueStore } from './storage';
import { createServerConfigService } from './serverConfigService';

describe('AuthStateService', () => {
  it('loads an unauthenticated state when no credentials are stored', async () => {
    const service = createAuthStateService({
      credentialStore: createCredentialStore(createMemoryKeyValueStore()),
      authService: { getToken: async () => 'unused-token' },
      randomBytes: () => Uint8Array.from(Array.from({ length: 32 }, (_, index) => index)),
    });

    await expect(service.loadSession()).resolves.toEqual({ status: 'unauthenticated' });
  });

  it('loads an authenticated state from stored credentials', async () => {
    const credentialStore = createCredentialStore(createMemoryKeyValueStore());
    await credentialStore.setCredentials({
      token: 'stored-token',
      secretBase64Url: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    });
    const service = createAuthStateService({
      credentialStore,
      authService: { getToken: async () => 'unused-token' },
      randomBytes: () => Uint8Array.from(Array.from({ length: 32 }, (_, index) => index)),
    });

    await expect(service.loadSession()).resolves.toEqual({
      status: 'authenticated',
      credentials: {
        token: 'stored-token',
        secretBase64Url: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
      },
    });
  });

  it('creates an account from 32 random secret bytes and persists the returned token', async () => {
    const secret = Uint8Array.from(Array.from({ length: 32 }, (_, index) => index));
    const credentialStore = createCredentialStore(createMemoryKeyValueStore());
    const getToken = vi.fn(async (input: Uint8Array) => {
      expect(input).toEqual(secret);
      return 'created-token';
    });
    const service = createAuthStateService({
      credentialStore,
      authService: { getToken },
      randomBytes: (length) => {
        expect(length).toBe(32);
        return secret;
      },
    });

    await expect(service.createAccount()).resolves.toEqual({
      token: 'created-token',
      secretBase64Url: encodeBase64Url(secret),
    });
    await expect(credentialStore.getCredentials()).resolves.toEqual({
      token: 'created-token',
      secretBase64Url: encodeBase64Url(secret),
    });
    expect(getToken).toHaveBeenCalledTimes(1);
  });

  it('does not persist a created account when the auth token is empty', async () => {
    const credentialStore = createCredentialStore(createMemoryKeyValueStore());
    const service = createAuthStateService({
      credentialStore,
      authService: { getToken: async () => '' },
      randomBytes: () => Uint8Array.from(Array.from({ length: 32 }, (_, index) => index)),
    });

    await expect(service.createAccount()).rejects.toThrow('Auth token is empty');
    await expect(credentialStore.getCredentials()).resolves.toBeNull();
  });

  it('restores an account from a formatted backup key and stores the normalized secret', async () => {
    const secret = Uint8Array.from(Array.from({ length: 32 }, (_, index) => index));
    const secretBase64Url = encodeBase64Url(secret);
    const credentialStore = createCredentialStore(createMemoryKeyValueStore());
    const service = createAuthStateService({
      credentialStore,
      authService: {
        getToken: async (input) => {
          expect(input).toEqual(secret);
          return 'restored-token';
        },
      },
      randomBytes: () => Uint8Array.from(Array.from({ length: 32 }, (_, index) => index + 1)),
    });

    await expect(service.restoreAccount(formatSecretKeyForBackup(secretBase64Url).toLowerCase())).resolves.toEqual({
      token: 'restored-token',
      secretBase64Url,
    });
    await expect(credentialStore.getCredentials()).resolves.toEqual({
      token: 'restored-token',
      secretBase64Url,
    });
  });

  it('does not overwrite existing credentials when restore input is invalid', async () => {
    const credentialStore = createCredentialStore(createMemoryKeyValueStore());
    await credentialStore.setCredentials({
      token: 'existing-token',
      secretBase64Url: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    });
    const service = createAuthStateService({
      credentialStore,
      authService: { getToken: async () => 'new-token' },
      randomBytes: () => Uint8Array.from(Array.from({ length: 32 }, (_, index) => index)),
    });

    await expect(service.restoreAccount('invalid-key')).rejects.toThrow();
    await expect(credentialStore.getCredentials()).resolves.toEqual({
      token: 'existing-token',
      secretBase64Url: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    });
  });

  it('logs out by clearing credentials without resetting the separate server config store', async () => {
    const storage = createMemoryKeyValueStore();
    const credentialStore = createCredentialStore(storage);
    const serverConfig = createServerConfigService({ storage });
    await credentialStore.setCredentials({
      token: 'stored-token',
      secretBase64Url: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    });
    serverConfig.setServerUrl('https://example.com/happy');
    const service = createAuthStateService({
      credentialStore,
      authService: { getToken: async () => 'unused-token' },
      randomBytes: () => Uint8Array.from(Array.from({ length: 32 }, (_, index) => index)),
    });

    await expect(service.logout()).resolves.toBeUndefined();

    await expect(credentialStore.getCredentials()).resolves.toBeNull();
    expect(serverConfig.getServerUrl()).toBe('https://example.com/happy');
  });
});
