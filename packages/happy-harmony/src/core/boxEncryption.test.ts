import { describe, expect, it } from 'vitest';
import nacl from 'tweetnacl';
import { createHash } from 'node:crypto';
import { decodeBase64, encodeBase64 } from './base64';
import {
  boxPublicKeyFromSeed,
  decryptBoxBundleForTest,
  encryptBoxWithSecretKey,
} from './boxEncryption';

describe('box encryption helpers', () => {
  it('encrypts NaCl box bundles that tweetnacl can decrypt', () => {
    const message = Uint8Array.from(Array.from({ length: 33 }, (_, index) => index));
    const senderSecretKey = Uint8Array.from(Array.from({ length: 32 }, (_, index) => index + 1));
    const recipientSecretKey = Uint8Array.from(Array.from({ length: 32 }, (_, index) => 255 - index));
    const recipientKeyPair = nacl.box.keyPair.fromSecretKey(recipientSecretKey);
    const nonce = Uint8Array.from(Array.from({ length: 24 }, (_, index) => index + 33));

    const bundle = encryptBoxWithSecretKey(message, recipientKeyPair.publicKey, senderSecretKey, nonce);
    const ephemeralPublicKey = bundle.slice(0, 32);
    const bundledNonce = bundle.slice(32, 56);
    const ciphertext = bundle.slice(56);
    const decrypted = nacl.box.open(ciphertext, bundledNonce, ephemeralPublicKey, recipientSecretKey);

    expect(decrypted).toEqual(message);
    expect(decryptBoxBundleForTest(bundle, recipientSecretKey)).toEqual(message);
  });

  it('derives libsodium-compatible crypto_box_seed_keypair public keys', () => {
    const seed = Uint8Array.from(Array.from({ length: 32 }, (_, index) => index));
    const hashedSeed = new Uint8Array(createHash('sha512').update(seed).digest()).slice(0, 32);
    const expected = nacl.box.keyPair.fromSecretKey(hashedSeed).publicKey;

    expect(boxPublicKeyFromSeed(seed)).toEqual(expected);
    expect(encodeBase64(boxPublicKeyFromSeed(decodeBase64('AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=')))).toBe(
      encodeBase64(expected),
    );
  });
});
