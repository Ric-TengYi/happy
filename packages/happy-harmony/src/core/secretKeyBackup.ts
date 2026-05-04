import { decodeBase64Url, encodeBase64Url } from './base64';

const BASE32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function formatSecretKeyForBackup(secretKeyBase64Url: string): string {
  const bytes = decodeBase64Url(secretKeyBase64Url);
  if (bytes.length !== 32) {
    throw new Error('Invalid secret key format');
  }
  const base32 = bytesToBase32(bytes);
  const groups: string[] = [];
  for (let index = 0; index < base32.length; index += 5) {
    groups.push(base32.slice(index, index + 5));
  }
  return groups.join('-');
}

export function normalizeSecretKey(value: string): string {
  const trimmed = value.trim();
  if (/[-\s]/.test(trimmed) || trimmed.length > 50) {
    return parseBackupSecretKey(trimmed);
  }

  try {
    const bytes = decodeBase64Url(trimmed);
    if (bytes.length !== 32) {
      throw new Error('Invalid secret key');
    }
    return trimmed;
  } catch {
    return parseBackupSecretKey(trimmed);
  }
}

function parseBackupSecretKey(formattedKey: string): string {
  const bytes = base32ToBytes(formattedKey);
  if (bytes.length !== 32) {
    throw new Error(`Invalid key length: expected 32 bytes, got ${bytes.length}`);
  }
  return encodeBase64Url(bytes);
}

function bytesToBase32(bytes: Uint8Array): string {
  let result = '';
  let buffer = 0;
  let bufferLength = 0;

  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bufferLength += 8;

    while (bufferLength >= 5) {
      bufferLength -= 5;
      result += BASE32_ALPHABET[(buffer >> bufferLength) & 0x1f];
    }
  }

  if (bufferLength > 0) {
    result += BASE32_ALPHABET[(buffer << (5 - bufferLength)) & 0x1f];
  }

  return result;
}

function base32ToBytes(base32: string): Uint8Array {
  const cleaned = base32
    .toUpperCase()
    .replace(/0/g, 'O')
    .replace(/1/g, 'I')
    .replace(/8/g, 'B')
    .replace(/9/g, 'G')
    .replace(/[^A-Z2-7]/g, '');

  if (!cleaned) {
    throw new Error('No valid characters found');
  }

  const bytes: number[] = [];
  let buffer = 0;
  let bufferLength = 0;

  for (const char of cleaned) {
    const value = BASE32_ALPHABET.indexOf(char);
    if (value === -1) {
      throw new Error('Invalid base32 character');
    }
    buffer = (buffer << 5) | value;
    bufferLength += 5;

    if (bufferLength >= 8) {
      bufferLength -= 8;
      bytes.push((buffer >> bufferLength) & 0xff);
    }
  }

  return new Uint8Array(bytes);
}
