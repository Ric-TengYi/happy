import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';

const DEFAULT_SERVER_URL: string = 'https://47.118.25.177';
const HAPPY_SERVER_MARKER: string = 'Welcome to Happy Server!';
const SERVER_PREFS: string = 'happy-server-config';
const SERVER_URL_KEY: string = 'custom-server-url';
const AUTH_TOKEN_ALIAS: string = 'happy-auth-token';
const AUTH_SECRET_ALIAS: string = 'happy-auth-secret';
const ASSET_NOT_FOUND_CODE: number = 24000002;
const ACCOUNT_SECRET_LENGTH: number = 32;
const ED25519_SIGNATURE_LENGTH: number = 64;
const BASE64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const BASE32_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
const ED25519_P: bigint = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffedn;
const ED25519_N: bigint = 0x1000000000000000000000000000000014def9dea2f79cd65812631a5cf5d3edn;
const ED25519_D: bigint = 0x52036cee2b6ffe738cc740797779e89800700a4d4141d8ab75eb4dca135978a3n;
const ED25519_A: bigint = ED25519_P - 1n;
const ED25519_GX: bigint = 0x216936d3cd6e53fec0a4e231fdd6dc5c692cc7609525a7b2c9562d608f25d51an;
const ED25519_GY: bigint = 0x6666666666666666666666666666666666666666666666666666666666666658n;
const ED25519_B256: bigint = 2n ** 256n;
const ED25519_SELF_TEST_PUBLIC_KEY: string = '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8';
const ED25519_SELF_TEST_SIGNATURE: string = '14a27374b4e03fd642d77ecaf9b9d46e9e427d757314de98e72cbaf7586b245bfeb02cce7054e43dab892e577b803ef3e73583db92856ee46e48f081eb35fa03';
let ed25519SelfTestCompleted: boolean = false;

export interface Credentials {
  token: string;
  secretBase64Url: string;
}

export interface AuthResult {
  credentials: Credentials;
  backupSecret: string;
}

interface AuthChallenge {
  publicKey: Uint8Array;
  challenge: Uint8Array;
  signature: Uint8Array;
}

interface AuthTokenResponse {
  token?: string;
}

interface GetHeaders {
  Accept: string;
}

interface AuthHeaders {
  'Content-Type': string;
  'X-Happy-Client': string;
}

interface AuthRequestBody {
  publicKey: string;
  challenge: string;
  signature: string;
}

interface TextResponse {
  ok: boolean;
  statusCode: number;
  text: string;
}

export function getDefaultServerUrl(): string {
  return DEFAULT_SERVER_URL;
}

export function getServerUrl(context: common.UIAbilityContext): string {
  const store = getPrefs(context, SERVER_PREFS);
  const stored = store.getSync(SERVER_URL_KEY, '') as string;
  return stored.length > 0 ? stored : DEFAULT_SERVER_URL;
}

export async function setServerUrl(context: common.UIAbilityContext, url: string): Promise<void> {
  const trimmed = url.trim();
  const store = getPrefs(context, SERVER_PREFS);
  if (trimmed.length > 0 && trimmed !== DEFAULT_SERVER_URL) {
    store.putSync(SERVER_URL_KEY, trimmed);
  } else {
    store.deleteSync(SERVER_URL_KEY);
  }
  await store.flush();
}

export function validateServerUrl(url: string): string | undefined {
  const trimmed = url.trim();
  if (trimmed.length === 0) {
    return '请输入服务器地址';
  }
  const schemeEnd = trimmed.indexOf('://');
  if (schemeEnd <= 0) {
    return '服务器地址格式不正确';
  }
  const scheme = trimmed.substring(0, schemeEnd);
  if (scheme !== 'http' && scheme !== 'https') {
    return '服务器地址必须以 http:// 或 https:// 开头';
  }
  const hostAndPath = trimmed.substring(schemeEnd + 3);
  if (hostAndPath.length === 0 || hostAndPath.startsWith('/') || hostAndPath.indexOf(' ') >= 0) {
    return '服务器地址格式不正确';
  }
  return undefined;
}

export async function validateHappyServer(url: string): Promise<boolean> {
  const headers: GetHeaders = {
    Accept: 'text/plain',
  };
  const response = await requestText(url, http.RequestMethod.GET, undefined, headers);
  return response.ok && response.text.includes(HAPPY_SERVER_MARKER);
}

export async function loadCredentials(context: common.UIAbilityContext): Promise<Credentials | null> {
  const token = await queryAssetString(AUTH_TOKEN_ALIAS);
  const secretBase64Url = await queryAssetString(AUTH_SECRET_ALIAS);
  if (!token || !secretBase64Url) {
    await removeStoredCredentials();
    return null;
  }
  try {
    assertAccountSecret(decodeBase64Url(secretBase64Url));
    return { token, secretBase64Url };
  } catch {
    await removeStoredCredentials();
    return null;
  }
}

export function formatBackupSecret(secretBase64Url: string): string {
  return formatSecretKeyForBackup(secretBase64Url);
}

export async function createAccount(context: common.UIAbilityContext, serverUrl: string): Promise<AuthResult> {
  const secret = randomBytes(ACCOUNT_SECRET_LENGTH);
  const normalizedServerUrl = normalizeServerUrl(serverUrl);
  const token = await requestAuthToken(normalizedServerUrl, secret);
  await setServerUrl(context, normalizedServerUrl);
  return saveCredentials(context, token, encodeBase64Url(secret));
}

export async function restoreAccount(
  context: common.UIAbilityContext,
  serverUrl: string,
  secretInput: string,
): Promise<AuthResult> {
  const normalized = normalizeSecretKey(secretInput);
  const secret = decodeBase64Url(normalized);
  assertAccountSecret(secret);
  const normalizedServerUrl = normalizeServerUrl(serverUrl);
  const token = await requestAuthToken(normalizedServerUrl, secret);
  await setServerUrl(context, normalizedServerUrl);
  return saveCredentials(context, token, encodeBase64Url(secret));
}

export async function logout(context: common.UIAbilityContext): Promise<void> {
  await removeStoredCredentials();
}

export function maskToken(token: string): string {
  if (token.length <= 16) {
    return token;
  }
  return `${token.substring(0, 8)}...${token.substring(token.length - 6)}`;
}

async function saveCredentials(context: common.UIAbilityContext, token: string, secretBase64Url: string): Promise<AuthResult> {
  try {
    await removeStoredCredentials();
    await addAssetString(AUTH_TOKEN_ALIAS, token);
    await addAssetString(AUTH_SECRET_ALIAS, secretBase64Url);
  } catch (error) {
    await rollbackCredentialSave(error as BusinessError);
  }
  const credentials: Credentials = { token, secretBase64Url };
  return {
    credentials,
    backupSecret: formatSecretKeyForBackup(secretBase64Url),
  };
}

function getPrefs(context: common.UIAbilityContext, name: string): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name });
}

async function addAssetString(alias: string, value: string): Promise<void> {
  const attributes: asset.AssetMap = new Map();
  attributes.set(asset.Tag.ALIAS, stringToBytes(alias));
  attributes.set(asset.Tag.SECRET, stringToBytes(value));
  attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
  await asset.add(attributes);
}

async function rollbackCredentialSave(cause: BusinessError): Promise<void> {
  try {
    await removeStoredCredentials();
  } catch (cleanupError) {
    throw new Error(`保存凭证失败，清理残留凭证失败：${(cleanupError as BusinessError).code}`);
  }
  throw new Error(`保存凭证失败：${cause.code}`);
}

async function queryAssetString(alias: string): Promise<string | null> {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, stringToBytes(alias));
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
  query.set(asset.Tag.RETURN_LIMIT, 1);
  try {
    const results = await asset.query(query);
    if (results.length === 0) {
      return null;
    }
    const secret = results[0].get(asset.Tag.SECRET);
    if (secret instanceof Uint8Array) {
      return bytesToString(secret);
    }
    return null;
  } catch (error) {
    if (isAssetNotFound(error as BusinessError)) {
      return null;
    }
    throw new Error(`读取凭证失败：${(error as BusinessError).code}`);
  }
}

async function removeStoredCredentials(): Promise<void> {
  await removeAssetIfExists(AUTH_TOKEN_ALIAS);
  await removeAssetIfExists(AUTH_SECRET_ALIAS);
}

async function removeAssetIfExists(alias: string): Promise<void> {
  try {
    await removeAsset(alias);
  } catch (error) {
    if (!isAssetNotFound(error as BusinessError)) {
      throw new Error(`删除凭证失败：${(error as BusinessError).code}`);
    }
  }
}

async function removeAsset(alias: string): Promise<void> {
  const query: asset.AssetMap = new Map();
  query.set(asset.Tag.ALIAS, stringToBytes(alias));
  await asset.remove(query);
}

function isAssetNotFound(error: BusinessError): boolean {
  return error.code === ASSET_NOT_FOUND_CODE;
}

async function requestAuthToken(serverUrl: string, secret: Uint8Array): Promise<string> {
  const auth = createAuthChallenge(secret);
  const requestBody: AuthRequestBody = {
    publicKey: encodeBase64(auth.publicKey),
    challenge: encodeBase64(auth.challenge),
    signature: encodeBase64(auth.signature),
  };
  const body = JSON.stringify(requestBody);
  const headers: AuthHeaders = {
    'Content-Type': 'application/json',
    'X-Happy-Client': 'harmony/0.1.0',
  };
  const response = await requestText(`${serverUrl}/v1/auth`, http.RequestMethod.POST, body, headers);
  if (!response.ok) {
    throw new Error(`服务器认证失败：${response.statusCode}`);
  }
  const data = JSON.parse(response.text) as AuthTokenResponse;
  if (!data.token || data.token.length === 0) {
    throw new Error('服务器未返回 token');
  }
  return data.token;
}

function normalizeServerUrl(url: string): string {
  let normalized = url.trim();
  while (normalized.length > 'https://'.length && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

function createAuthChallenge(secret: Uint8Array): AuthChallenge {
  const challenge = randomBytes(ACCOUNT_SECRET_LENGTH);
  try {
    ensureEd25519SelfTest();
    const publicKey = getEd25519PublicKey(secret);
    const signature = signEd25519(challenge, secret);
    return {
      publicKey,
      challenge,
      signature,
    };
  } catch (error) {
    throw new Error(`鸿蒙 Ed25519 签名暂不可用：${error}`);
  }
}

function randomBytes(length: number): Uint8Array {
  return cryptoFramework.createRandom().generateRandomSync(length).data;
}

class Ed25519Point {
  readonly x: bigint;
  readonly y: bigint;
  readonly z: bigint;
  readonly t: bigint;

  constructor(x: bigint, y: bigint, z: bigint, t: bigint) {
    this.x = assertEd25519Range(x, 0n, ED25519_B256);
    this.y = assertEd25519Range(y, 0n, ED25519_B256);
    this.z = assertEd25519Range(z, 1n, ED25519_B256);
    this.t = assertEd25519Range(t, 0n, ED25519_B256);
  }

  equals(other: Ed25519Point): boolean {
    return ed25519Mod(this.x * other.z) === ed25519Mod(other.x * this.z)
      && ed25519Mod(this.y * other.z) === ed25519Mod(other.y * this.z);
  }

  negate(): Ed25519Point {
    return new Ed25519Point(ed25519Mod(-this.x), this.y, this.z, ed25519Mod(-this.t));
  }

  double(): Ed25519Point {
    const a = ed25519Mod(this.x * this.x);
    const b = ed25519Mod(this.y * this.y);
    const c = ed25519Mod(2n * ed25519Mod(this.z * this.z));
    const d = ed25519Mod(ED25519_A * a);
    const e = ed25519Mod(ed25519Mod((this.x + this.y) * (this.x + this.y)) - a - b);
    const g = d + b;
    const f = g - c;
    const h = d - b;
    return new Ed25519Point(
      ed25519Mod(e * f),
      ed25519Mod(g * h),
      ed25519Mod(f * g),
      ed25519Mod(e * h),
    );
  }

  add(other: Ed25519Point): Ed25519Point {
    const a = ed25519Mod(this.x * other.x);
    const b = ed25519Mod(this.y * other.y);
    const c = ed25519Mod(this.t * ED25519_D * other.t);
    const d = ed25519Mod(this.z * other.z);
    const e = ed25519Mod((this.x + this.y) * (other.x + other.y) - a - b);
    const f = ed25519Mod(d - c);
    const g = ed25519Mod(d + c);
    const h = ed25519Mod(b - ED25519_A * a);
    return new Ed25519Point(
      ed25519Mod(e * f),
      ed25519Mod(g * h),
      ed25519Mod(f * g),
      ed25519Mod(e * h),
    );
  }

  multiply(scalar: bigint): Ed25519Point {
    if (scalar === 0n || this.equals(ED25519_ZERO)) {
      return ED25519_ZERO;
    }
    let point = ED25519_ZERO;
    let addend: Ed25519Point = this;
    let remaining = scalar;
    while (remaining > 0n) {
      if ((remaining & 1n) === 1n) {
        point = point.add(addend);
      }
      addend = addend.double();
      remaining >>= 1n;
    }
    return point;
  }

  toBytes(): Uint8Array {
    const affine = this.toAffine();
    const bytes = bigIntToLittleEndian(affine.y, ACCOUNT_SECRET_LENGTH);
    if ((affine.x & 1n) === 1n) {
      bytes[31] |= 0x80;
    }
    return bytes;
  }

  private toAffine(): Ed25519AffinePoint {
    if (this.equals(ED25519_ZERO)) {
      return { x: 0n, y: 1n };
    }
    const iz = ed25519Invert(this.z);
    return {
      x: ed25519Mod(this.x * iz),
      y: ed25519Mod(this.y * iz),
    };
  }
}

interface Ed25519AffinePoint {
  x: bigint;
  y: bigint;
}

interface Ed25519ExpandedSecret {
  publicKey: Uint8Array;
  prefix: Uint8Array;
  scalar: bigint;
}

const ED25519_BASE: Ed25519Point = new Ed25519Point(
  ED25519_GX,
  ED25519_GY,
  1n,
  ed25519Mod(ED25519_GX * ED25519_GY),
);
const ED25519_ZERO: Ed25519Point = new Ed25519Point(0n, 1n, 1n, 0n);

function getEd25519PublicKey(seed: Uint8Array): Uint8Array {
  return expandEd25519Secret(seed).publicKey;
}

function ensureEd25519SelfTest(): void {
  if (ed25519SelfTestCompleted) {
    return;
  }
  const seed = new Uint8Array(ACCOUNT_SECRET_LENGTH);
  const challenge = new Uint8Array(ACCOUNT_SECRET_LENGTH);
  for (let index = 0; index < ACCOUNT_SECRET_LENGTH; index += 1) {
    seed[index] = index;
    challenge[index] = 255 - index;
  }
  const digest = sha512(seed);
  const publicKey = getEd25519PublicKey(seed);
  const signature = signEd25519(challenge, seed);
  if (!bytesEqual(publicKey, hexToBytes(ED25519_SELF_TEST_PUBLIC_KEY))
    || !bytesEqual(signature, hexToBytes(ED25519_SELF_TEST_SIGNATURE))) {
    throw new Error(`Ed25519 自检失败：digest=${bytesToHex(digest)}`);
  }
  ed25519SelfTestCompleted = true;
}

function signEd25519(message: Uint8Array, seed: Uint8Array): Uint8Array {
  const expanded = expandEd25519Secret(seed);
  const r = ed25519ReduceLittleEndian(sha512(expanded.prefix, message));
  const rBytes = ED25519_BASE.multiply(r).toBytes();
  const k = ed25519ReduceLittleEndian(sha512(rBytes, expanded.publicKey, message));
  const s = ed25519ModN(r + k * expanded.scalar);
  return concatBytes(rBytes, bigIntToLittleEndian(s, ACCOUNT_SECRET_LENGTH));
}

function expandEd25519Secret(seed: Uint8Array): Ed25519ExpandedSecret {
  assertAccountSecret(seed);
  const digest = sha512(seed);
  const head = digest.slice(0, ACCOUNT_SECRET_LENGTH);
  head[0] &= 248;
  head[31] &= 127;
  head[31] |= 64;
  const scalar = ed25519ReduceLittleEndian(head);
  return {
    publicKey: ED25519_BASE.multiply(scalar).toBytes(),
    prefix: digest.slice(ACCOUNT_SECRET_LENGTH, ED25519_SIGNATURE_LENGTH),
    scalar,
  };
}

function sha512(...chunks: Uint8Array[]): Uint8Array {
  const digest = cryptoFramework.createMd('SHA512');
  digest.updateSync({ data: concatBytes(...chunks) });
  return digest.digestSync().data;
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

function ed25519ReduceLittleEndian(bytes: Uint8Array): bigint {
  return ed25519ModN(littleEndianToBigInt(bytes));
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

function ed25519Mod(value: bigint): bigint {
  const result = value % ED25519_P;
  return result >= 0n ? result : ED25519_P + result;
}

function ed25519ModN(value: bigint): bigint {
  const result = value % ED25519_N;
  return result >= 0n ? result : ED25519_N + result;
}

function ed25519Invert(value: bigint): bigint {
  if (value === 0n) {
    throw new Error('Ed25519 inverse of zero');
  }
  let a = ed25519Mod(value);
  let b = ED25519_P;
  let x = 0n;
  let y = 1n;
  let u = 1n;
  let v = 0n;
  while (a !== 0n) {
    const quotient = b / a;
    const remainder = b % a;
    const nextX = x - u * quotient;
    const nextY = y - v * quotient;
    b = a;
    a = remainder;
    x = u;
    y = v;
    u = nextX;
    v = nextY;
  }
  if (b !== 1n) {
    throw new Error('Ed25519 inverse does not exist');
  }
  return ed25519Mod(x);
}

function assertEd25519Range(value: bigint, min: bigint, max: bigint): bigint {
  if (value < min || value >= max) {
    throw new Error('Ed25519 number out of range');
  }
  return value;
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

function bytesToHex(bytes: Uint8Array): string {
  let result = '';
  for (const byte of bytes) {
    result += byte.toString(16).padStart(2, '0');
  }
  return result;
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(hex.substring(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

async function requestText(
  url: string,
  method: http.RequestMethod,
  body: string | undefined,
  headers: Object,
): Promise<TextResponse> {
  const request = http.createHttp();
  try {
    const response = await request.request(url, {
      method,
      extraData: body,
      header: headers,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000,
      readTimeout: 8000,
    });
    return {
      ok: response.responseCode >= 200 && response.responseCode < 300,
      statusCode: response.responseCode,
      text: toResponseText(response.result),
    };
  } finally {
    request.destroy();
  }
}

function toResponseText(result: string | Object | ArrayBuffer): string {
  if (typeof result === 'string') {
    return result;
  }
  if (result instanceof ArrayBuffer) {
    return '';
  }
  return JSON.stringify(result);
}

function assertAccountSecret(secret: Uint8Array): void {
  if (secret.length !== ACCOUNT_SECRET_LENGTH) {
    throw new Error('密钥必须是 32 字节');
  }
}

function encodeBase64Url(bytes: Uint8Array): string {
  return encodeBase64(bytes)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=/g, '');
}

function decodeBase64Url(base64url: string): Uint8Array {
  const base64 = base64url
    .replace(/-/g, '+')
    .replace(/_/g, '/');
  const padding = base64.length % 4;
  return decodeBase64(padding === 0 ? base64 : base64 + '='.repeat(4 - padding));
}

function encodeBase64(bytes: Uint8Array): string {
  let result = '';
  for (let index = 0; index < bytes.length; index += 3) {
    const first = bytes[index];
    const second = index + 1 < bytes.length ? bytes[index + 1] : 0;
    const third = index + 2 < bytes.length ? bytes[index + 2] : 0;
    const combined = (first << 16) | (second << 8) | third;
    result += BASE64_ALPHABET[(combined >> 18) & 0x3f];
    result += BASE64_ALPHABET[(combined >> 12) & 0x3f];
    result += index + 1 < bytes.length ? BASE64_ALPHABET[(combined >> 6) & 0x3f] : '=';
    result += index + 2 < bytes.length ? BASE64_ALPHABET[combined & 0x3f] : '=';
  }
  return result;
}

function decodeBase64(base64: string): Uint8Array {
  const cleaned = base64.replace(/\s/g, '');
  const bytes: number[] = [];
  for (let index = 0; index < cleaned.length; index += 4) {
    const first = base64Index(cleaned[index]);
    const second = base64Index(cleaned[index + 1]);
    const third = cleaned[index + 2] === '=' ? 0 : base64Index(cleaned[index + 2]);
    const fourth = cleaned[index + 3] === '=' ? 0 : base64Index(cleaned[index + 3]);
    const combined = (first << 18) | (second << 12) | (third << 6) | fourth;
    bytes.push((combined >> 16) & 0xff);
    if (cleaned[index + 2] !== '=') {
      bytes.push((combined >> 8) & 0xff);
    }
    if (cleaned[index + 3] !== '=') {
      bytes.push(combined & 0xff);
    }
  }
  return new Uint8Array(bytes);
}

function base64Index(char: string): number {
  const index = BASE64_ALPHABET.indexOf(char);
  if (index < 0) {
    throw new Error('密钥格式不正确');
  }
  return index;
}

function normalizeSecretKey(value: string): string {
  const trimmed = value.trim();
  if (/[-\s]/.test(trimmed) || trimmed.length > 50) {
    return parseBackupSecretKey(trimmed);
  }

  try {
    assertAccountSecret(decodeBase64Url(trimmed));
    return trimmed;
  } catch {
    return parseBackupSecretKey(trimmed);
  }
}

function formatSecretKeyForBackup(secretKeyBase64Url: string): string {
  const bytes = decodeBase64Url(secretKeyBase64Url);
  assertAccountSecret(bytes);
  const base32 = bytesToBase32(bytes);
  const groups: string[] = [];
  for (let index = 0; index < base32.length; index += 5) {
    groups.push(base32.slice(index, index + 5));
  }
  return groups.join('-');
}

function parseBackupSecretKey(formattedKey: string): string {
  const bytes = base32ToBytes(formattedKey);
  assertAccountSecret(bytes);
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
  if (cleaned.length === 0) {
    throw new Error('密钥格式不正确');
  }

  const bytes: number[] = [];
  let buffer = 0;
  let bufferLength = 0;
  for (const char of cleaned) {
    const value = BASE32_ALPHABET.indexOf(char);
    if (value < 0) {
      throw new Error('密钥格式不正确');
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

function stringToBytes(value: string): Uint8Array {
  const bytes = new Uint8Array(value.length);
  for (let index = 0; index < value.length; index += 1) {
    bytes[index] = value.charCodeAt(index) & 0xff;
  }
  return bytes;
}

function bytesToString(bytes: Uint8Array): string {
  let value = '';
  for (const byte of bytes) {
    value += String.fromCharCode(byte);
  }
  return value;
}
