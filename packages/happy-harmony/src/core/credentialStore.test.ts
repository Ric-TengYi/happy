import { describe, expect, it } from 'vitest';
import { createCredentialStore } from './credentialStore';
import { createMemoryKeyValueStore } from './storage';

describe('CredentialStore', () => {
  it('stores, reads, and removes token and account secret together', async () => {
    const store = createCredentialStore(createMemoryKeyValueStore());

    await expect(store.getCredentials()).resolves.toBeNull();

    await expect(store.setCredentials({
      token: 'token-1',
      secretBase64Url: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    })).resolves.toBe(true);

    await expect(store.getCredentials()).resolves.toEqual({
      token: 'token-1',
      secretBase64Url: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8',
    });

    await expect(store.removeCredentials()).resolves.toBe(true);
    await expect(store.getCredentials()).resolves.toBeNull();
  });
});
