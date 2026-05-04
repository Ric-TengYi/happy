import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { Credentials, loadCredentials } from './HappyAuth';
import { decryptBoxBundle, decryptSecretBox, deriveContentSecretKey } from './HappyBox';

const HAPPY_CLIENT_ID: string = 'harmony/0.1.0';
const BASE64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const ACCOUNT_SECRET_LENGTH: number = 32;
const DATA_KEY_LENGTH: number = 32;
const AES_GCM_VERSION: number = 0;
const AES_GCM_NONCE_LENGTH: number = 12;
const AES_GCM_AUTH_TAG_LENGTH: number = 16;

interface AuthHeaders {
  'Authorization': string;
  'Content-Type': string;
  'X-Happy-Client': string;
}

interface TextResponse {
  ok: boolean;
  statusCode: number;
  text: string;
}

interface SessionWireEnvelope {
  sessions?: SessionWire[];
}

interface MachineWire {
  id: string;
  seq: number;
  createdAt: number;
  updatedAt: number;
  active: boolean;
  activeAt: number;
  metadata?: string | null;
  metadataVersion: number;
  daemonState?: string | null;
  daemonStateVersion?: number;
  dataEncryptionKey?: string | null;
}

interface SessionWire {
  id: string;
  seq: number;
  createdAt: number;
  updatedAt: number;
  active: boolean;
  activeAt: number;
  metadata: string;
  metadataVersion: number;
  agentState?: string | null;
  agentStateVersion: number;
  dataEncryptionKey?: string | null;
}

export interface MachineAvailability {
  claude?: boolean;
  codex?: boolean;
  gemini?: boolean;
  openclaw?: boolean;
  detectedAt?: number;
}

export interface MachineMetadata {
  host?: string;
  platform?: string;
  happyCliVersion?: string;
  happyHomeDir?: string;
  homeDir?: string;
  username?: string;
  arch?: string;
  displayName?: string;
  daemonLastKnownStatus?: string;
  cliAvailability?: MachineAvailability;
}

export interface SessionSummary {
  text: string;
  updatedAt: number;
}

export interface SessionMetadata {
  path?: string;
  host?: string;
  version?: string;
  name?: string;
  os?: string;
  machineId?: string;
  homeDir?: string;
  flavor?: string | null;
  summary?: SessionSummary;
}

export interface HappyMachine {
  id: string;
  seq: number;
  createdAt: number;
  updatedAt: number;
  active: boolean;
  activeAt: number;
  metadata: MachineMetadata | null;
  metadataVersion: number;
  daemonState: Object | null;
  daemonStateVersion: number;
  dataEncryptionKey: string | null;
}

export interface HappySession {
  id: string;
  seq: number;
  createdAt: number;
  updatedAt: number;
  active: boolean;
  activeAt: number;
  metadata: SessionMetadata | null;
  metadataVersion: number;
  agentState: Object | null;
  agentStateVersion: number;
  dataEncryptionKey: string | null;
}

export interface ControlPlaneSnapshot {
  machines: HappyMachine[];
  sessions: HappySession[];
  decodeWarningCount: number;
}

interface ControlPlaneCounts {
  machines: HappyMachine[];
  sessions: HappySession[];
}

interface DecodeStats {
  failures: number;
}

interface RecordCipher {
  key: Uint8Array;
  isDataKey: boolean;
}

export async function loadControlPlaneSnapshot(
  context: common.UIAbilityContext,
  serverUrl: string,
): Promise<ControlPlaneSnapshot> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }

  const normalizedServerUrl = normalizeServerUrl(serverUrl);
  const headers: AuthHeaders = {
    'Authorization': `Bearer ${credentials.token}`,
    'Content-Type': 'application/json',
    'X-Happy-Client': HAPPY_CLIENT_ID,
  };
  const responses = await Promise.all([
    requestText(`${normalizedServerUrl}/v1/machines`, headers),
    requestText(`${normalizedServerUrl}/v1/sessions`, headers),
  ]);
  const machinesResponse = responses[0];
  const sessionsResponse = responses[1];
  if (!machinesResponse.ok) {
    throw new Error(`读取终端列表失败：${machinesResponse.statusCode}`);
  }
  if (!sessionsResponse.ok) {
    throw new Error(`读取会话列表失败：${sessionsResponse.statusCode}`);
  }

  const machineRows = parseMachines(machinesResponse.text);
  const sessionRows = parseSessions(sessionsResponse.text);
  const decodeStats: DecodeStats = { failures: 0 };
  return {
    machines: machineRows.map((row: MachineWire): HappyMachine => decryptMachine(row, credentials, decodeStats)),
    sessions: sessionRows.map((row: SessionWire): HappySession => decryptSession(row, credentials, decodeStats)),
    decodeWarningCount: decodeStats.failures,
  };
}

export function getMachineTitle(machine: HappyMachine): string {
  const displayName = normalizeOptionalText(machine.metadata?.displayName);
  if (displayName.length > 0) {
    return displayName;
  }
  const host = normalizeOptionalText(machine.metadata?.host);
  return host.length > 0 ? host : machine.id;
}

export function getMachineSubtitle(machine: HappyMachine): string {
  const parts: string[] = [machine.active ? '在线' : '离线'];
  const platform = normalizeOptionalText(machine.metadata?.platform);
  if (platform.length > 0) {
    parts.push(platform);
  }
  const cliVersion = normalizeOptionalText(machine.metadata?.happyCliVersion);
  if (cliVersion.length > 0) {
    parts.push(`CLI ${cliVersion}`);
  }
  return parts.join(' · ');
}

export function getSessionTitle(session: HappySession): string {
  const summary = normalizeOptionalText(session.metadata?.summary?.text);
  if (summary.length > 0) {
    return summary;
  }
  const name = normalizeOptionalText(session.metadata?.name);
  if (name.length > 0) {
    return name;
  }
  const path = normalizeOptionalText(session.metadata?.path);
  if (path.length > 0) {
    const parts = path.split('/').filter((part: string): boolean => part.length > 0);
    if (parts.length > 0) {
      return parts[parts.length - 1];
    }
    return path;
  }
  return session.id;
}

export function getSessionSubtitle(session: HappySession): string {
  const host = normalizeOptionalText(session.metadata?.host);
  const path = normalizeOptionalText(session.metadata?.path);
  if (host.length > 0 && path.length > 0) {
    return `${host} · ${path}`;
  }
  if (path.length > 0) {
    return path;
  }
  return session.active ? '会话在线' : formatRelativeTime(session.activeAt);
}

export function getControlPlaneSummary(snapshot: ControlPlaneCounts): string {
  const onlineMachines = snapshot.machines.filter((machine: HappyMachine): boolean => machine.active).length;
  const activeSessions = snapshot.sessions.filter((session: HappySession): boolean => session.active).length;
  return `${onlineMachines}/${snapshot.machines.length} 台终端在线，${activeSessions}/${snapshot.sessions.length} 个会话活跃`;
}

function decryptMachine(row: MachineWire, credentials: Credentials, decodeStats: DecodeStats): HappyMachine {
  const cipher = resolveRecordCipher(row.dataEncryptionKey ?? null, credentials);
  const metadata = decryptRecordWithCipher(row.metadata ?? null, cipher, decodeStats) as MachineMetadata | null;
  const daemonState = decryptRecordWithCipher(row.daemonState ?? null, cipher, decodeStats);
  return {
    id: row.id,
    seq: row.seq,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    active: row.active,
    activeAt: row.activeAt,
    metadata,
    metadataVersion: row.metadataVersion,
    daemonState,
    daemonStateVersion: row.daemonStateVersion ?? 0,
    dataEncryptionKey: row.dataEncryptionKey ?? null,
  };
}

function decryptSession(row: SessionWire, credentials: Credentials, decodeStats: DecodeStats): HappySession {
  const cipher = resolveRecordCipher(row.dataEncryptionKey ?? null, credentials);
  const metadata = decryptRecordWithCipher(row.metadata, cipher, decodeStats) as SessionMetadata | null;
  const agentState = decryptRecordWithCipher(row.agentState ?? null, cipher, decodeStats);
  return {
    id: row.id,
    seq: row.seq,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    active: row.active,
    activeAt: row.activeAt,
    metadata,
    metadataVersion: row.metadataVersion,
    agentState,
    agentStateVersion: row.agentStateVersion,
    dataEncryptionKey: row.dataEncryptionKey ?? null,
  };
}

function decryptRecordWithCipher(encrypted: string | null, cipher: RecordCipher | null, decodeStats: DecodeStats): Object | null {
  if (!encrypted || encrypted.length === 0) {
    return null;
  }
  if (!cipher) {
    decodeStats.failures += 1;
    return null;
  }

  try {
    const encryptedBytes = decodeBase64(encrypted);
    const plain = cipher.isDataKey ? decryptAesGcm(encryptedBytes, cipher.key) : decryptSecretBox(encryptedBytes, cipher.key);
    if (!plain) {
      decodeStats.failures += 1;
      return null;
    }
    const parsed = JSON.parse(bytesToUtf8String(plain)) as Object;
    if (typeof parsed === 'object' && parsed !== null) {
      return parsed;
    }
    decodeStats.failures += 1;
    return null;
  } catch (error) {
    console.error(`记录解密失败：${error}`);
    decodeStats.failures += 1;
    return null;
  }
}

function resolveRecordCipher(dataEncryptionKey: string | null, credentials: Credentials): RecordCipher | null {
  let accountSecret: Uint8Array;
  try {
    accountSecret = decodeBase64Url(credentials.secretBase64Url);
  } catch (error) {
    console.error(`账号密钥解析失败：${error}`);
    return null;
  }
  if (accountSecret.length !== ACCOUNT_SECRET_LENGTH) {
    return null;
  }
  if (!dataEncryptionKey || dataEncryptionKey.length === 0) {
    return { key: accountSecret, isDataKey: false };
  }

  let wrappedKey: Uint8Array;
  try {
    wrappedKey = decodeBase64(dataEncryptionKey);
  } catch (error) {
    console.error(`数据密钥解析失败：${error}`);
    return null;
  }
  if (wrappedKey.length < 1 || wrappedKey[0] !== 0) {
    return null;
  }
  try {
    const dataKey = decryptBoxBundle(wrappedKey.slice(1), deriveContentSecretKey(accountSecret));
    if (!dataKey || dataKey.length !== DATA_KEY_LENGTH) {
      return null;
    }
    return { key: dataKey, isDataKey: true };
  } catch (error) {
    console.error(`数据密钥解密失败：${error}`);
    return null;
  }
}

function decryptAesGcm(bundle: Uint8Array, keyBytes: Uint8Array): Uint8Array | null {
  if (bundle.length < 1 + AES_GCM_NONCE_LENGTH + AES_GCM_AUTH_TAG_LENGTH || bundle[0] !== AES_GCM_VERSION) {
    return null;
  }
  const nonce = bundle.slice(1, 1 + AES_GCM_NONCE_LENGTH);
  const authTag = bundle.slice(bundle.length - AES_GCM_AUTH_TAG_LENGTH);
  const ciphertext = bundle.slice(1 + AES_GCM_NONCE_LENGTH, bundle.length - AES_GCM_AUTH_TAG_LENGTH);
  try {
    const key = cryptoFramework.createSymKeyGenerator('AES256').convertKeySync({ data: keyBytes });
    const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
    const params: cryptoFramework.GcmParamsSpec = {
      iv: { data: nonce },
      aad: { data: new Uint8Array() },
      authTag: { data: authTag },
      algName: 'GcmParamsSpec',
    };
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, key, params);
    return cipher.doFinalSync({ data: ciphertext }).data;
  } catch (error) {
    console.error(`AES-GCM 解密失败：${error}`);
    return null;
  }
}

function parseMachines(text: string): MachineWire[] {
  const parsed = JSON.parse(text) as MachineWire[];
  if (!Array.isArray(parsed)) {
    throw new Error('终端列表响应格式不正确');
  }
  return parsed;
}

function parseSessions(text: string): SessionWire[] {
  const parsed = JSON.parse(text) as SessionWireEnvelope;
  if (!parsed.sessions || !Array.isArray(parsed.sessions)) {
    throw new Error('会话列表响应格式不正确');
  }
  return parsed.sessions;
}

async function requestText(url: string, headers: Object): Promise<TextResponse> {
  const request = http.createHttp();
  try {
    const response = await request.request(url, {
      method: http.RequestMethod.GET,
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

function normalizeServerUrl(url: string): string {
  let normalized = url.trim();
  while (normalized.length > 'https://'.length && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

function formatRelativeTime(timestamp: number): string {
  if (timestamp <= 0) {
    return '暂无活跃时间';
  }
  const diffMs = Math.max(0, Date.now() - timestamp);
  const diffMinutes = Math.floor(diffMs / 60000);
  if (diffMinutes < 1) {
    return '刚刚活跃';
  }
  if (diffMinutes < 60) {
    return `${diffMinutes} 分钟前活跃`;
  }
  const diffHours = Math.floor(diffMinutes / 60);
  if (diffHours < 24) {
    return `${diffHours} 小时前活跃`;
  }
  const diffDays = Math.floor(diffHours / 24);
  return `${diffDays} 天前活跃`;
}

function normalizeOptionalText(value: string | undefined | null): string {
  return value ? value.trim() : '';
}

function bytesToUtf8String(bytes: Uint8Array): string {
  return buffer.from(bytes).toString('utf8');
}

function decodeBase64Url(base64url: string): Uint8Array {
  return decodeBase64(base64url.replace(/-/g, '+').replace(/_/g, '/'));
}

function decodeBase64(base64: string): Uint8Array {
  const cleaned = base64.replace(/\s/g, '');
  const padded = cleaned + '='.repeat((4 - cleaned.length % 4) % 4);
  const bytes: number[] = [];
  for (let index = 0; index < padded.length; index += 4) {
    const first = base64Index(padded[index]);
    const second = base64Index(padded[index + 1]);
    const third = padded[index + 2] === '=' ? 0 : base64Index(padded[index + 2]);
    const fourth = padded[index + 3] === '=' ? 0 : base64Index(padded[index + 3]);
    const combined = (first << 18) | (second << 12) | (third << 6) | fourth;
    bytes.push((combined >> 16) & 0xff);
    if (padded[index + 2] !== '=') {
      bytes.push((combined >> 8) & 0xff);
    }
    if (padded[index + 3] !== '=') {
      bytes.push(combined & 0xff);
    }
  }
  return new Uint8Array(bytes);
}

function base64Index(char: string): number {
  const index = BASE64_ALPHABET.indexOf(char);
  if (index < 0) {
    throw new Error('Base64 内容格式不正确');
  }
  return index;
}
