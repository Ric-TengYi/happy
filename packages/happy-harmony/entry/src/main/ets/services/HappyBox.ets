import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const BOX_KEY_LENGTH: number = 32;
const BOX_NONCE_LENGTH: number = 24;
const BOX_MAC_LENGTH: number = 16;
const HMAC_SHA512_BLOCK_LENGTH: number = 128;
const X25519_P: bigint = (1n << 255n) - 19n;
const X25519_A24: bigint = 121665n;
const SIGMA: Uint8Array = new Uint8Array([101, 120, 112, 97, 110, 100, 32, 51, 50, 45, 98, 121, 116, 101, 32, 107]);

export function encryptBox(message: Uint8Array, recipientPublicKey: Uint8Array): Uint8Array {
  const senderSecretKey = randomBytes(BOX_KEY_LENGTH);
  const nonce = randomBytes(BOX_NONCE_LENGTH);
  return encryptBoxWithSecretKey(message, recipientPublicKey, senderSecretKey, nonce);
}

export function deriveContentPublicKey(masterSecret: Uint8Array): Uint8Array {
  const contentSeed = deriveKey(masterSecret, 'Happy EnCoder', ['content']);
  return boxPublicKeyFromSeed(contentSeed);
}

export function deriveContentSecretKey(masterSecret: Uint8Array): Uint8Array {
  const contentSeed = deriveKey(masterSecret, 'Happy EnCoder', ['content']);
  return sha512(contentSeed).slice(0, BOX_KEY_LENGTH);
}

export function decryptBoxBundle(bundle: Uint8Array, recipientSecretKey: Uint8Array): Uint8Array | null {
  assertLength(recipientSecretKey, BOX_KEY_LENGTH, '内容私钥');
  if (bundle.length < BOX_KEY_LENGTH + BOX_NONCE_LENGTH + BOX_MAC_LENGTH) {
    return null;
  }
  const senderPublicKey = bundle.slice(0, BOX_KEY_LENGTH);
  const nonce = bundle.slice(BOX_KEY_LENGTH, BOX_KEY_LENGTH + BOX_NONCE_LENGTH);
  const ciphertext = bundle.slice(BOX_KEY_LENGTH + BOX_NONCE_LENGTH);
  return secretBoxOpenEasy(ciphertext, nonce, boxBeforeNm(senderPublicKey, recipientSecretKey));
}

export function decryptSecretBox(bundle: Uint8Array, secretKey: Uint8Array): Uint8Array | null {
  assertLength(secretKey, BOX_KEY_LENGTH, '记录密钥');
  if (bundle.length < BOX_NONCE_LENGTH + BOX_MAC_LENGTH) {
    return null;
  }
  const nonce = bundle.slice(0, BOX_NONCE_LENGTH);
  const ciphertext = bundle.slice(BOX_NONCE_LENGTH);
  return secretBoxOpenEasy(ciphertext, nonce, secretKey);
}

export function encryptSecretBox(message: Uint8Array, secretKey: Uint8Array): Uint8Array {
  assertLength(secretKey, BOX_KEY_LENGTH, '记录密钥');
  const nonce = randomBytes(BOX_NONCE_LENGTH);
  return concatBytes(nonce, secretBoxEasy(message, nonce, secretKey));
}

function encryptBoxWithSecretKey(
  message: Uint8Array,
  recipientPublicKey: Uint8Array,
  senderSecretKey: Uint8Array,
  nonce: Uint8Array,
): Uint8Array {
  assertLength(recipientPublicKey, BOX_KEY_LENGTH, '终端公钥');
  assertLength(senderSecretKey, BOX_KEY_LENGTH, '临时私钥');
  assertLength(nonce, BOX_NONCE_LENGTH, '加密 nonce');

  const senderPublicKey = scalarMultBase(senderSecretKey);
  const sharedKey = boxBeforeNm(recipientPublicKey, senderSecretKey);
  const ciphertext = secretBoxEasy(message, nonce, sharedKey);
  return concatBytes(senderPublicKey, nonce, ciphertext);
}

function boxPublicKeyFromSeed(seed: Uint8Array): Uint8Array {
  assertLength(seed, BOX_KEY_LENGTH, '内容密钥种子');
  return scalarMultBase(sha512(seed).slice(0, BOX_KEY_LENGTH));
}

function deriveKey(master: Uint8Array, usage: string, path: string[]): Uint8Array {
  let state = splitKeyTreeState(hmacSha512(stringToBytes(`${usage} Master Seed`), master));
  for (const item of path) {
    const encoded = stringToBytes(item);
    const data = new Uint8Array(encoded.length + 1);
    data[0] = 0;
    data.set(encoded, 1);
    state = splitKeyTreeState(hmacSha512(state.chainCode, data));
  }
  return state.key;
}

function splitKeyTreeState(bytes: Uint8Array): KeyTreeState {
  if (bytes.length !== 64) {
    throw new Error('HMAC-SHA512 输出长度不正确');
  }
  return {
    key: bytes.slice(0, BOX_KEY_LENGTH),
    chainCode: bytes.slice(BOX_KEY_LENGTH),
  };
}

interface KeyTreeState {
  key: Uint8Array;
  chainCode: Uint8Array;
}

function boxBeforeNm(publicKey: Uint8Array, secretKey: Uint8Array): Uint8Array {
  const shared = scalarMult(secretKey, publicKey);
  return hsalsa20(new Uint8Array(16), shared);
}

function secretBoxEasy(message: Uint8Array, nonce: Uint8Array, key: Uint8Array): Uint8Array {
  const stream = xsalsa20Stream(32 + message.length, nonce, key);
  const encrypted = new Uint8Array(message.length);
  for (let index = 0; index < message.length; index += 1) {
    encrypted[index] = message[index] ^ stream[index + 32];
  }
  return concatBytes(poly1305Mac(encrypted, stream.slice(0, 32)), encrypted);
}

function secretBoxOpenEasy(box: Uint8Array, nonce: Uint8Array, key: Uint8Array): Uint8Array | null {
  if (box.length < BOX_MAC_LENGTH) {
    return null;
  }
  const mac = box.slice(0, BOX_MAC_LENGTH);
  const encrypted = box.slice(BOX_MAC_LENGTH);
  const stream = xsalsa20Stream(32 + encrypted.length, nonce, key);
  const expectedMac = poly1305Mac(encrypted, stream.slice(0, 32));
  if (!bytesEqual(mac, expectedMac)) {
    return null;
  }
  const message = new Uint8Array(encrypted.length);
  for (let index = 0; index < encrypted.length; index += 1) {
    message[index] = encrypted[index] ^ stream[index + 32];
  }
  return message;
}

function xsalsa20Stream(length: number, nonce: Uint8Array, key: Uint8Array): Uint8Array {
  assertLength(nonce, BOX_NONCE_LENGTH, 'XSalsa20 nonce');
  assertLength(key, BOX_KEY_LENGTH, 'XSalsa20 key');
  const subKey = hsalsa20(nonce.slice(0, 16), key);
  return salsa20Stream(length, nonce.slice(16, 24), subKey);
}

function salsa20Stream(length: number, nonce: Uint8Array, key: Uint8Array): Uint8Array {
  const out = new Uint8Array(length);
  const input = new Uint8Array(16);
  input.set(nonce, 0);
  let offset = 0;
  while (offset < length) {
    const block = salsa20Block(input, key);
    const chunkLength = Math.min(64, length - offset);
    out.set(block.slice(0, chunkLength), offset);
    incrementCounter(input);
    offset += chunkLength;
  }
  return out;
}

function incrementCounter(input: Uint8Array): void {
  let carry = 1;
  for (let index = 8; index < 16; index += 1) {
    const value = input[index] + carry;
    input[index] = value & 0xff;
    carry = value >>> 8;
    if (carry === 0) {
      return;
    }
  }
}

function salsa20Block(input: Uint8Array, key: Uint8Array): Uint8Array {
  let x0 = load32(SIGMA, 0);
  let x1 = load32(key, 0);
  let x2 = load32(key, 4);
  let x3 = load32(key, 8);
  let x4 = load32(key, 12);
  let x5 = load32(SIGMA, 4);
  let x6 = load32(input, 0);
  let x7 = load32(input, 4);
  let x8 = load32(input, 8);
  let x9 = load32(input, 12);
  let x10 = load32(SIGMA, 8);
  let x11 = load32(key, 16);
  let x12 = load32(key, 20);
  let x13 = load32(key, 24);
  let x14 = load32(key, 28);
  let x15 = load32(SIGMA, 12);
  const original = new Array<number>(
    x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15,
  );

  for (let index = 0; index < 20; index += 2) {
    x4 ^= rotateLeft(add32(x0, x12), 7);
    x8 ^= rotateLeft(add32(x4, x0), 9);
    x12 ^= rotateLeft(add32(x8, x4), 13);
    x0 ^= rotateLeft(add32(x12, x8), 18);
    x9 ^= rotateLeft(add32(x5, x1), 7);
    x13 ^= rotateLeft(add32(x9, x5), 9);
    x1 ^= rotateLeft(add32(x13, x9), 13);
    x5 ^= rotateLeft(add32(x1, x13), 18);
    x14 ^= rotateLeft(add32(x10, x6), 7);
    x2 ^= rotateLeft(add32(x14, x10), 9);
    x6 ^= rotateLeft(add32(x2, x14), 13);
    x10 ^= rotateLeft(add32(x6, x2), 18);
    x3 ^= rotateLeft(add32(x15, x11), 7);
    x7 ^= rotateLeft(add32(x3, x15), 9);
    x11 ^= rotateLeft(add32(x7, x3), 13);
    x15 ^= rotateLeft(add32(x11, x7), 18);
    x1 ^= rotateLeft(add32(x0, x3), 7);
    x2 ^= rotateLeft(add32(x1, x0), 9);
    x3 ^= rotateLeft(add32(x2, x1), 13);
    x0 ^= rotateLeft(add32(x3, x2), 18);
    x6 ^= rotateLeft(add32(x5, x4), 7);
    x7 ^= rotateLeft(add32(x6, x5), 9);
    x4 ^= rotateLeft(add32(x7, x6), 13);
    x5 ^= rotateLeft(add32(x4, x7), 18);
    x11 ^= rotateLeft(add32(x10, x9), 7);
    x8 ^= rotateLeft(add32(x11, x10), 9);
    x9 ^= rotateLeft(add32(x8, x11), 13);
    x10 ^= rotateLeft(add32(x9, x8), 18);
    x12 ^= rotateLeft(add32(x15, x14), 7);
    x13 ^= rotateLeft(add32(x12, x15), 9);
    x14 ^= rotateLeft(add32(x13, x12), 13);
    x15 ^= rotateLeft(add32(x14, x13), 18);
  }

  const out = new Uint8Array(64);
  const mixed = new Array<number>(
    x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14, x15,
  );
  for (let index = 0; index < mixed.length; index += 1) {
    store32(out, index * 4, add32(mixed[index], original[index]));
  }
  return out;
}

function hsalsa20(input: Uint8Array, key: Uint8Array): Uint8Array {
  let x0 = load32(SIGMA, 0);
  let x1 = load32(key, 0);
  let x2 = load32(key, 4);
  let x3 = load32(key, 8);
  let x4 = load32(key, 12);
  let x5 = load32(SIGMA, 4);
  let x6 = load32(input, 0);
  let x7 = load32(input, 4);
  let x8 = load32(input, 8);
  let x9 = load32(input, 12);
  let x10 = load32(SIGMA, 8);
  let x11 = load32(key, 16);
  let x12 = load32(key, 20);
  let x13 = load32(key, 24);
  let x14 = load32(key, 28);
  let x15 = load32(SIGMA, 12);

  for (let index = 0; index < 20; index += 2) {
    x4 ^= rotateLeft(add32(x0, x12), 7);
    x8 ^= rotateLeft(add32(x4, x0), 9);
    x12 ^= rotateLeft(add32(x8, x4), 13);
    x0 ^= rotateLeft(add32(x12, x8), 18);
    x9 ^= rotateLeft(add32(x5, x1), 7);
    x13 ^= rotateLeft(add32(x9, x5), 9);
    x1 ^= rotateLeft(add32(x13, x9), 13);
    x5 ^= rotateLeft(add32(x1, x13), 18);
    x14 ^= rotateLeft(add32(x10, x6), 7);
    x2 ^= rotateLeft(add32(x14, x10), 9);
    x6 ^= rotateLeft(add32(x2, x14), 13);
    x10 ^= rotateLeft(add32(x6, x2), 18);
    x3 ^= rotateLeft(add32(x15, x11), 7);
    x7 ^= rotateLeft(add32(x3, x15), 9);
    x11 ^= rotateLeft(add32(x7, x3), 13);
    x15 ^= rotateLeft(add32(x11, x7), 18);
    x1 ^= rotateLeft(add32(x0, x3), 7);
    x2 ^= rotateLeft(add32(x1, x0), 9);
    x3 ^= rotateLeft(add32(x2, x1), 13);
    x0 ^= rotateLeft(add32(x3, x2), 18);
    x6 ^= rotateLeft(add32(x5, x4), 7);
    x7 ^= rotateLeft(add32(x6, x5), 9);
    x4 ^= rotateLeft(add32(x7, x6), 13);
    x5 ^= rotateLeft(add32(x4, x7), 18);
    x11 ^= rotateLeft(add32(x10, x9), 7);
    x8 ^= rotateLeft(add32(x11, x10), 9);
    x9 ^= rotateLeft(add32(x8, x11), 13);
    x10 ^= rotateLeft(add32(x9, x8), 18);
    x12 ^= rotateLeft(add32(x15, x14), 7);
    x13 ^= rotateLeft(add32(x12, x15), 9);
    x14 ^= rotateLeft(add32(x13, x12), 13);
    x15 ^= rotateLeft(add32(x14, x13), 18);
  }

  const out = new Uint8Array(32);
  const values = new Array<number>(x0, x5, x10, x15, x6, x7, x8, x9);
  for (let index = 0; index < values.length; index += 1) {
    store32(out, index * 4, values[index]);
  }
  return out;
}

function poly1305Mac(message: Uint8Array, key: Uint8Array): Uint8Array {
  const rBytes = key.slice(0, 16);
  rBytes[3] &= 15;
  rBytes[7] &= 15;
  rBytes[11] &= 15;
  rBytes[15] &= 15;
  rBytes[4] &= 252;
  rBytes[8] &= 252;
  rBytes[12] &= 252;

  const r = littleEndianToBigInt(rBytes);
  const s = littleEndianToBigInt(key.slice(16, 32));
  const p = (1n << 130n) - 5n;
  let accumulator = 0n;
  for (let offset = 0; offset < message.length; offset += 16) {
    const block = message.slice(offset, Math.min(offset + 16, message.length));
    accumulator = ((accumulator + littleEndianWithOneBit(block)) * r) % p;
  }
  return bigIntToLittleEndian((accumulator + s) % (1n << 128n), 16);
}

function scalarMultBase(secretKey: Uint8Array): Uint8Array {
  const base = new Uint8Array(BOX_KEY_LENGTH);
  base[0] = 9;
  return scalarMult(secretKey, base);
}

function scalarMult(secretKey: Uint8Array, publicKey: Uint8Array): Uint8Array {
  const scalar = clampScalar(secretKey);
  const x1 = littleEndianToBigInt(publicKey) & ((1n << 255n) - 1n);
  let x2 = 1n;
  let z2 = 0n;
  let x3 = x1;
  let z3 = 1n;
  let swap = 0n;
  for (let bit = 254; bit >= 0; bit -= 1) {
    const current = (scalar >> BigInt(bit)) & 1n;
    swap ^= current;
    if (swap === 1n) {
      const tempX = x2;
      const tempZ = z2;
      x2 = x3;
      z2 = z3;
      x3 = tempX;
      z3 = tempZ;
    }
    swap = current;
    const a = modP(x2 + z2);
    const aa = modP(a * a);
    const b = modP(x2 - z2);
    const bb = modP(b * b);
    const e = modP(aa - bb);
    const c = modP(x3 + z3);
    const d = modP(x3 - z3);
    const da = modP(d * a);
    const cb = modP(c * b);
    x3 = modP((da + cb) ** 2n);
    z3 = modP(x1 * modP((da - cb) ** 2n));
    x2 = modP(aa * bb);
    z2 = modP(e * modP(aa + X25519_A24 * e));
  }
  if (swap === 1n) {
    const tempX = x2;
    const tempZ = z2;
    x2 = x3;
    z2 = z3;
    x3 = tempX;
    z3 = tempZ;
  }
  return bigIntToLittleEndian(modP(x2 * modPow(z2, X25519_P - 2n, X25519_P)), BOX_KEY_LENGTH);
}

function clampScalar(secretKey: Uint8Array): bigint {
  assertLength(secretKey, BOX_KEY_LENGTH, 'X25519 私钥');
  const scalar = new Uint8Array(secretKey);
  scalar[0] &= 248;
  scalar[31] &= 127;
  scalar[31] |= 64;
  return littleEndianToBigInt(scalar);
}

function hmacSha512(key: Uint8Array, data: Uint8Array): Uint8Array {
  const normalizedKey = key.length > HMAC_SHA512_BLOCK_LENGTH ? sha512(key) : key;
  const paddedKey = new Uint8Array(HMAC_SHA512_BLOCK_LENGTH);
  paddedKey.set(normalizedKey, 0);
  const inner = new Uint8Array(HMAC_SHA512_BLOCK_LENGTH);
  const outer = new Uint8Array(HMAC_SHA512_BLOCK_LENGTH);
  for (let index = 0; index < HMAC_SHA512_BLOCK_LENGTH; index += 1) {
    inner[index] = paddedKey[index] ^ 0x36;
    outer[index] = paddedKey[index] ^ 0x5c;
  }
  return sha512(outer, sha512(inner, data));
}

function sha512(...chunks: Uint8Array[]): Uint8Array {
  const digest = cryptoFramework.createMd('SHA512');
  digest.updateSync({ data: concatBytes(...chunks) });
  return digest.digestSync().data;
}

function randomBytes(length: number): Uint8Array {
  return cryptoFramework.createRandom().generateRandomSync(length).data;
}

function modPow(base: bigint, exponent: bigint, modulo: bigint): bigint {
  let result = 1n;
  let factor = modPositive(base, modulo);
  let remaining = exponent;
  while (remaining > 0n) {
    if ((remaining & 1n) === 1n) {
      result = (result * factor) % modulo;
    }
    factor = (factor * factor) % modulo;
    remaining >>= 1n;
  }
  return result;
}

function modP(value: bigint): bigint {
  return modPositive(value, X25519_P);
}

function modPositive(value: bigint, modulo: bigint): bigint {
  const result = value % modulo;
  return result >= 0n ? result : result + modulo;
}

function littleEndianWithOneBit(bytes: Uint8Array): bigint {
  return littleEndianToBigInt(bytes) + (1n << BigInt(bytes.length * 8));
}

function littleEndianToBigInt(bytes: Uint8Array): bigint {
  let value = 0n;
  for (let index = bytes.length - 1; index >= 0; index -= 1) {
    value = (value << 8n) | BigInt(bytes[index]);
  }
  return value;
}

function bigIntToLittleEndian(value: bigint, length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  let remaining = value;
  for (let index = 0; index < length; index += 1) {
    bytes[index] = Number(remaining & 0xffn);
    remaining >>= 8n;
  }
  return bytes;
}

function load32(bytes: Uint8Array, offset: number): number {
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}

function store32(bytes: Uint8Array, offset: number, value: number): void {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >>> 8) & 0xff;
  bytes[offset + 2] = (value >>> 16) & 0xff;
  bytes[offset + 3] = (value >>> 24) & 0xff;
}

function add32(left: number, right: number): number {
  return (left + right) >>> 0;
}

function rotateLeft(value: number, count: number): number {
  return ((value << count) | (value >>> (32 - count))) >>> 0;
}

function concatBytes(...chunks: Uint8Array[]): Uint8Array {
  let length = 0;
  for (const chunk of chunks) {
    length += chunk.length;
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}

function stringToBytes(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index += 1) {
    bytes[index] = value.charCodeAt(index) & 0xff;
  }
  return bytes;
}

function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false;
  }
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) {
      return false;
    }
  }
  return true;
}

function assertLength(bytes: Uint8Array, length: number, label: string): void {
  if (bytes.length !== length) {
    throw new Error(`${label}必须是 ${length} 字节`);
  }
}
