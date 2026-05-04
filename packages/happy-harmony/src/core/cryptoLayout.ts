import { decodeBase64 } from './base64';

export type HmacSha512 = (key: Uint8Array, data: Uint8Array) => Uint8Array | Promise<Uint8Array>;

export async function deriveKey(
  master: Uint8Array,
  usage: string,
  path: string[],
  hmacSha512: HmacSha512,
): Promise<Uint8Array> {
  let state = splitKeyTreeState(
    await hmacSha512(utf8(`${usage} Master Seed`), master),
  );

  for (const item of path) {
    const encoded = utf8(item);
    const data = new Uint8Array(encoded.length + 1);
    data[0] = 0;
    data.set(encoded, 1);
    state = splitKeyTreeState(await hmacSha512(state.chainCode, data));
  }

  return state.key;
}

export function parseDataEncryptionKeyBundle(base64: string): {
  version: 0;
  boxBundle: Uint8Array;
} {
  const decoded = decodeBase64(base64);
  if (decoded.length < 1 || decoded[0] !== 0) {
    throw new Error('Unsupported data encryption key version');
  }
  if (decoded.length < 1 + 32 + 24 + 16) {
    throw new Error('Data encryption key bundle is too short');
  }
  return {
    version: 0,
    boxBundle: decoded.slice(1),
  };
}

export function parseDataKeyRecord(base64: string): {
  version: 0;
  nonce: Uint8Array;
  ciphertext: Uint8Array;
  authTag: Uint8Array;
} {
  const decoded = decodeBase64(base64);
  if (decoded.length < 1 + 12 + 16 || decoded[0] !== 0) {
    throw new Error('Unsupported data-key record');
  }
  return {
    version: 0,
    nonce: decoded.slice(1, 13),
    ciphertext: decoded.slice(13, decoded.length - 16),
    authTag: decoded.slice(decoded.length - 16),
  };
}

export function parseLegacySecretBoxRecord(base64: string): {
  nonce: Uint8Array;
  ciphertext: Uint8Array;
} {
  const decoded = decodeBase64(base64);
  if (decoded.length < 24 + 16) {
    throw new Error('Legacy secretbox record is too short');
  }
  return {
    nonce: decoded.slice(0, 24),
    ciphertext: decoded.slice(24),
  };
}

function splitKeyTreeState(bytes: Uint8Array): { key: Uint8Array; chainCode: Uint8Array } {
  if (bytes.length !== 64) {
    throw new Error('HMAC-SHA512 output must be 64 bytes');
  }
  return {
    key: bytes.slice(0, 32),
    chainCode: bytes.slice(32),
  };
}

function utf8(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}
