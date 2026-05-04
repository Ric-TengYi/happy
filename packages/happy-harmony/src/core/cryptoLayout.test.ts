import { createHmac } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  decodeBase64,
  decodeBase64Url,
  encodeBase64,
  encodeBase64Url,
} from './base64';
import {
  deriveKey,
  parseDataEncryptionKeyBundle,
  parseDataKeyRecord,
  parseLegacySecretBoxRecord,
} from './cryptoLayout';
import {
  formatSecretKeyForBackup,
  normalizeSecretKey,
} from './secretKeyBackup';

function hmacSha512(key: Uint8Array, data: Uint8Array): Uint8Array {
  const hmac = createHmac('sha512', key);
  hmac.update(data);
  return new Uint8Array(hmac.digest());
}

describe('crypto layout helpers', () => {
  it('round trips standard base64 and base64url without padding', () => {
    const bytes = Uint8Array.from([251, 255, 0, 1, 2, 3]);

    expect(encodeBase64(bytes)).toBe('+/8AAQID');
    expect(decodeBase64('+/8AAQID')).toEqual(bytes);
    expect(encodeBase64Url(bytes)).toBe('-_8AAQID');
    expect(decodeBase64Url('-_8AAQID')).toEqual(bytes);
  });

  it('derives Happy content keys with the existing HMAC-SHA512 tree', async () => {
    const secret = Uint8Array.from(Array.from({ length: 32 }, (_, index) => index));

    const derived = await deriveKey(secret, 'Happy EnCoder', ['content'], hmacSha512);

    expect(Buffer.from(derived).toString('hex')).toBe(
      '67eebf3ff0eb241774d2f6e45e4869ca3e01785630dae7635428076e725351be',
    );
  });

  it('parses encrypted data key bundles with the version byte stripped', () => {
    const boxBundle = Uint8Array.from([
      ...Array.from({ length: 32 }, (_, index) => index),
      ...Array.from({ length: 24 }, (_, index) => index + 32),
      ...Array.from({ length: 16 }, (_, index) => index + 80),
    ]);
    const bundle = Uint8Array.from([0, ...boxBundle]);

    expect(parseDataEncryptionKeyBundle(encodeBase64(bundle))).toEqual({
      version: 0,
      boxBundle,
    });

    expect(() => parseDataEncryptionKeyBundle(encodeBase64(Uint8Array.from([0, 1, 2, 3])))).toThrow(
      'Data encryption key bundle is too short',
    );
  });

  it('parses data-key and legacy record byte layouts', () => {
    const dataKeyRecord = Uint8Array.from([0, ...Array.from({ length: 12 }, (_, index) => index + 1), 40, 41, ...Array.from({ length: 16 }, (_, index) => index + 60)]);
    expect(parseDataKeyRecord(encodeBase64(dataKeyRecord))).toEqual({
      version: 0,
      nonce: Uint8Array.from(Array.from({ length: 12 }, (_, index) => index + 1)),
      ciphertext: Uint8Array.from([40, 41]),
      authTag: Uint8Array.from(Array.from({ length: 16 }, (_, index) => index + 60)),
    });

    const legacyCiphertext = Uint8Array.from(Array.from({ length: 18 }, (_, index) => index + 90));
    const legacy = Uint8Array.from([...Array.from({ length: 24 }, (_, index) => index), ...legacyCiphertext]);
    expect(parseLegacySecretBoxRecord(encodeBase64(legacy))).toEqual({
      nonce: Uint8Array.from(Array.from({ length: 24 }, (_, index) => index)),
      ciphertext: legacyCiphertext,
    });

    expect(() => parseLegacySecretBoxRecord(encodeBase64(Uint8Array.from(Array.from({ length: 24 }, (_, index) => index))))).toThrow(
      'Legacy secretbox record is too short',
    );
  });

  it('formats and normalizes backup secrets using Happy base32 rules', () => {
    const secret = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
    const formatted = 'AAAQE-AYEAU-DAOCA-JBIFQ-YDIOB-4IBCE-QTCQK-RMFYY-DENBW-HA5DY-PQ';

    expect(formatSecretKeyForBackup(secret)).toBe(formatted);
    expect(normalizeSecretKey(formatted.toLowerCase().replace(/-/g, ' '))).toBe(secret);
  });
});
