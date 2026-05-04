import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { Credentials, loadCredentials } from './HappyAuth';
import { HappySession } from './HappySync';
import { decryptBoxBundle, decryptSecretBox, deriveContentSecretKey } from './HappyBox';

const HAPPY_CLIENT_ID: string = 'harmony/0.1.0';
const BASE64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const ACCOUNT_SECRET_LENGTH: number = 32;
const DATA_KEY_LENGTH: number = 32;
const AES_GCM_VERSION: number = 0;
const AES_GCM_NONCE_LENGTH: number = 12;
const AES_GCM_AUTH_TAG_LENGTH: number = 16;
const PAGE_LIMIT: number = 100;
const TOOL_OUTPUT_MAX_LENGTH: number = 240;

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

interface SessionMessagesWireEnvelope {
  messages?: SessionMessageWire[];
  hasMore?: boolean;
}

interface SessionMessageWireContent {
  t?: string;
  c?: string;
}

interface SessionMessageWire {
  id: string;
  seq: number;
  content: SessionMessageWireContent;
  localId?: string | null;
  createdAt: number;
  updatedAt: number;
}

interface RecordCipher {
  key: Uint8Array;
  isDataKey: boolean;
}

interface DecodeStats {
  failures: number;
}

interface MessageBase {
  id: string;
  localId: string | null;
  seq: number;
  createdAt: number;
}

interface RawRecordWire {
  role?: string;
  content?: Object | Object[] | string;
}

interface RawAgentContentWire {
  type?: string;
  data?: Object;
  provider?: string;
}

interface ProviderEventWire {
  type?: string;
  message?: string;
  text?: string;
  callId?: string;
  id?: string;
  name?: string;
  output?: Object | Object[] | string;
  content?: Object | Object[] | string;
  isError?: boolean;
  is_error?: boolean;
  permissionId?: string;
  toolName?: string;
  data?: string;
}

interface OutputWire {
  type?: string;
  result?: string | null;
  summary?: string;
  message?: Object;
  isMeta?: boolean;
  isCompactSummary?: boolean;
}

interface OutputMessageWire {
  content?: Object[] | string;
}

interface AgentContentItemWire {
  type?: string;
  text?: string;
  thinking?: string;
  name?: string;
  id?: string;
  callId?: string;
  tool_use_id?: string;
  content?: Object | Object[] | string;
  output?: Object | Object[] | string;
  is_error?: boolean;
  isError?: boolean;
}

interface SessionEnvelopeWire {
  data?: Object;
  role?: string;
  ev?: Object;
}

interface SessionEventWire {
  t?: string;
  text?: string;
  thinking?: boolean;
  name?: string;
  title?: string;
  call?: string;
  ref?: string;
}

export interface HappyMessage {
  id: string;
  localId: string | null;
  seq: number;
  createdAt: number;
  role: string;
  kind: string;
  text: string;
  toolName: string;
  callId: string;
  isError: boolean;
}

export interface SessionMessagesSnapshot {
  messages: HappyMessage[];
  lastSeq: number;
  decodeWarningCount: number;
}

export async function loadSessionMessages(
  context: common.UIAbilityContext,
  serverUrl: string,
  session: HappySession,
): Promise<SessionMessagesSnapshot> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }

  const cipher = resolveRecordCipher(session.dataEncryptionKey, credentials);
  if (!cipher) {
    throw new Error('会话密钥不可用');
  }

  const normalizedServerUrl = normalizeServerUrl(serverUrl);
  const headers: AuthHeaders = {
    'Authorization': `Bearer ${credentials.token}`,
    'Content-Type': 'application/json',
    'X-Happy-Client': HAPPY_CLIENT_ID,
  };
  const decodeStats: DecodeStats = { failures: 0 };
  const messages: HappyMessage[] = [];
  let afterSeq: number = 0;
  let lastSeq: number = 0;
  let hasMore: boolean = true;

  while (hasMore) {
    const response = await requestText(
      `${normalizedServerUrl}/v3/sessions/${encodePathSegment(session.id)}/messages?after_seq=${afterSeq}&limit=${PAGE_LIMIT}`,
      headers,
    );
    if (!response.ok) {
      throw new Error(`读取消息失败：${response.statusCode}`);
    }

    const page = parseMessagesResponse(response.text);
    let maxSeq = afterSeq;
    for (let index = 0; index < page.messages.length; index += 1) {
      const row = page.messages[index];
      if (row.seq > maxSeq) {
        maxSeq = row.seq;
      }
      const raw = decryptMessageContent(row.content, cipher, decodeStats);
      if (raw) {
        messages.push(...normalizeRawMessage({
          id: row.id,
          localId: row.localId ?? null,
          seq: row.seq,
          createdAt: row.createdAt,
        }, raw));
      }
    }

    lastSeq = Math.max(lastSeq, maxSeq);
    hasMore = page.hasMore === true;
    if (hasMore && maxSeq === afterSeq) {
      break;
    }
    afterSeq = maxSeq;
  }

  return {
    messages,
    lastSeq,
    decodeWarningCount: decodeStats.failures,
  };
}

export function getMessageRoleLabel(message: HappyMessage): string {
  if (message.role === 'user') {
    return '我';
  }
  if (message.kind === 'thinking') {
    return '思考';
  }
  if (message.kind === 'tool-call') {
    return '工具';
  }
  if (message.kind === 'tool-result') {
    return message.isError ? '工具错误' : '工具结果';
  }
  if (message.role === 'system') {
    return '系统';
  }
  return 'Happy';
}

function decryptMessageContent(content: SessionMessageWireContent, cipher: RecordCipher, decodeStats: DecodeStats): Object | null {
  if (!content || content.t !== 'encrypted' || !content.c || content.c.length === 0) {
    decodeStats.failures += 1;
    return null;
  }
  try {
    const encryptedBytes = decodeBase64(content.c);
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
    console.error(`消息解密失败：${error}`);
    decodeStats.failures += 1;
    return null;
  }
}

function normalizeRawMessage(base: MessageBase, raw: Object): HappyMessage[] {
  const record = raw as RawRecordWire;
  if (record.role === 'user') {
    return textRows(base, 'user', record.content);
  }
  if (record.role === 'session') {
    return normalizeSessionEnvelope(base, record.content as Object);
  }
  if (record.role === 'agent') {
    return normalizeAgentContent(base, record.content);
  }
  return [];
}

function normalizeAgentContent(base: MessageBase, content: Object | Object[] | string | undefined): HappyMessage[] {
  if (typeof content !== 'object' || content === null || Array.isArray(content)) {
    return [];
  }
  const wrapper = content as RawAgentContentWire;
  if (wrapper.type === 'codex' || wrapper.type === 'acp') {
    return normalizeProviderEvent(base, wrapper.data, wrapper.provider ?? wrapper.type);
  }
  if (wrapper.type === 'session') {
    return normalizeSessionEnvelope(base, wrapper.data);
  }
  if (wrapper.type !== 'output' || !wrapper.data) {
    return [];
  }

  const output = wrapper.data as OutputWire;
  if (output.isMeta === true || output.isCompactSummary === true) {
    return [];
  }
  if (output.type === 'result') {
    return textRows(base, 'agent', output.result ?? '');
  }
  if (output.type === 'summary') {
    return textRows(base, 'agent', output.summary ?? '');
  }
  if ((output.type === 'assistant' || output.type === 'user') && output.message) {
    const message = output.message as OutputMessageWire;
    return contentRows(base, output.type === 'user' ? 'user' : 'agent', message.content);
  }
  return [];
}

function normalizeProviderEvent(base: MessageBase, eventObject: Object | undefined, provider: string): HappyMessage[] {
  if (!eventObject) {
    return [];
  }
  const event = eventObject as ProviderEventWire;
  if (event.type === 'message') {
    return textRows(base, 'agent', event.message ?? '');
  }
  if (event.type === 'reasoning') {
    return makeRows(base, [{
      role: 'agent',
      kind: 'thinking',
      text: event.message ?? '',
      toolName: '',
      callId: '',
      isError: false,
    }]);
  }
  if (event.type === 'thinking') {
    return makeRows(base, [{
      role: 'agent',
      kind: 'thinking',
      text: event.text ?? '',
      toolName: '',
      callId: '',
      isError: false,
    }]);
  }
  if (event.type === 'tool-call') {
    const toolName = normalizeOptionalText(event.name) || 'unknown';
    return makeRows(base, [{
      role: 'agent',
      kind: 'tool-call',
      text: `调用工具：${toolName}`,
      toolName,
      callId: normalizeOptionalText(event.callId) || normalizeOptionalText(event.id),
      isError: false,
    }]);
  }
  if (event.type === 'tool-result' || event.type === 'tool-call-result') {
    return makeRows(base, [{
      role: 'agent',
      kind: 'tool-result',
      text: `工具结果：${summarizeToolOutput(event.output ?? event.content)}`,
      toolName: '',
      callId: normalizeOptionalText(event.callId) || normalizeOptionalText(event.id),
      isError: event.isError === true || event.is_error === true,
    }]);
  }
  if (event.type === 'permission-request') {
    const toolName = normalizeOptionalText(event.toolName) || provider;
    return makeRows(base, [{
      role: 'agent',
      kind: 'tool-call',
      text: `权限请求：${toolName}`,
      toolName,
      callId: normalizeOptionalText(event.permissionId),
      isError: false,
    }]);
  }
  if (event.type === 'terminal-output') {
    return makeRows(base, [{
      role: 'agent',
      kind: 'tool-result',
      text: `工具结果：${summarizeToolOutput(event.data ?? '')}`,
      toolName: '',
      callId: normalizeOptionalText(event.callId),
      isError: false,
    }]);
  }
  if (event.type === 'file-edit') {
    return makeRows(base, [{
      role: 'agent',
      kind: 'tool-call',
      text: '调用工具：file-edit',
      toolName: 'file-edit',
      callId: normalizeOptionalText(event.id),
      isError: false,
    }]);
  }
  return [];
}

function normalizeSessionEnvelope(base: MessageBase, content: Object | undefined): HappyMessage[] {
  if (!content) {
    return [];
  }
  const wrapper = content as SessionEnvelopeWire;
  const envelope = wrapper.data ? wrapper.data as SessionEnvelopeWire : wrapper;
  if (!envelope.ev) {
    return [];
  }
  const event = envelope.ev as SessionEventWire;
  const role = envelope.role === 'user' ? 'user' : 'agent';
  if (event.t === 'text') {
    return makeRows(base, [{
      role,
      kind: event.thinking === true ? 'thinking' : 'text',
      text: event.text ?? '',
      toolName: '',
      callId: '',
      isError: false,
    }]);
  }
  if (event.t === 'service') {
    return makeRows(base, [{
      role: 'system',
      kind: 'service',
      text: event.text ?? '',
      toolName: '',
      callId: '',
      isError: false,
    }]);
  }
  if (event.t === 'tool-call-start') {
    const toolName = normalizeOptionalText(event.name) || normalizeOptionalText(event.title) || 'unknown';
    return makeRows(base, [{
      role: 'agent',
      kind: 'tool-call',
      text: `调用工具：${toolName}`,
      toolName,
      callId: normalizeOptionalText(event.call),
      isError: false,
    }]);
  }
  if (event.t === 'tool-call-end') {
    return makeRows(base, [{
      role: 'agent',
      kind: 'tool-result',
      text: '工具调用结束',
      toolName: '',
      callId: normalizeOptionalText(event.call),
      isError: false,
    }]);
  }
  if (event.t === 'file') {
    return makeRows(base, [{
      role,
      kind: 'tool-call',
      text: `文件：${normalizeOptionalText(event.name)}`,
      toolName: 'file',
      callId: normalizeOptionalText(event.ref),
      isError: false,
    }]);
  }
  return [];
}

function contentRows(base: MessageBase, role: string, content: Object[] | string | undefined): HappyMessage[] {
  if (typeof content === 'string') {
    return textRows(base, role, content);
  }
  if (!Array.isArray(content)) {
    return [];
  }
  const rows: HappyMessage[] = [];
  for (let index = 0; index < content.length; index += 1) {
    const rawItem = content[index];
    if (typeof rawItem !== 'object' || rawItem === null || Array.isArray(rawItem)) {
      continue;
    }
    const item = rawItem as AgentContentItemWire;
    if (item.type === 'text') {
      rows.push(makeMessage(base, rows.length, role, 'text', item.text ?? '', '', '', false));
    } else if (item.type === 'thinking') {
      rows.push(makeMessage(base, rows.length, role, 'thinking', item.thinking ?? '', '', '', false));
    } else if (item.type === 'tool_use' || item.type === 'tool-call') {
      const toolName = normalizeOptionalText(item.name) || 'unknown';
      rows.push(makeMessage(
        base,
        rows.length,
        'agent',
        'tool-call',
        `调用工具：${toolName}`,
        toolName,
        normalizeOptionalText(item.id) || normalizeOptionalText(item.callId),
        false,
      ));
    } else if (item.type === 'tool_result' || item.type === 'tool-call-result') {
      rows.push(makeMessage(
        base,
        rows.length,
        'agent',
        'tool-result',
        `工具结果：${summarizeToolOutput(item.content ?? item.output)}`,
        '',
        normalizeOptionalText(item.tool_use_id) || normalizeOptionalText(item.callId),
        item.is_error === true || item.isError === true,
      ));
    }
  }
  return rows.filter((row: HappyMessage): boolean => row.text.length > 0);
}

function textRows(base: MessageBase, role: string, content: Object | Object[] | string | null | undefined): HappyMessage[] {
  if (typeof content === 'string') {
    return makeRows(base, [{
      role,
      kind: 'text',
      text: content,
      toolName: '',
      callId: '',
      isError: false,
    }]);
  }
  if (typeof content === 'object' && content !== null && !Array.isArray(content)) {
    const item = content as AgentContentItemWire;
    if (item.type === 'text') {
      return makeRows(base, [{
        role,
        kind: 'text',
        text: item.text ?? '',
        toolName: '',
        callId: '',
        isError: false,
      }]);
    }
  }
  if (Array.isArray(content)) {
    return contentRows(base, role, content);
  }
  return [];
}

function makeRows(base: MessageBase, parts: MessagePart[]): HappyMessage[] {
  const rows: HappyMessage[] = [];
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    const text = part.text.trim();
    if (text.length > 0) {
      rows.push(makeMessage(base, rows.length, part.role, part.kind, text, part.toolName, part.callId, part.isError));
    }
  }
  return rows;
}

interface MessagePart {
  role: string;
  kind: string;
  text: string;
  toolName: string;
  callId: string;
  isError: boolean;
}

function makeMessage(
  base: MessageBase,
  index: number,
  role: string,
  kind: string,
  text: string,
  toolName: string,
  callId: string,
  isError: boolean,
): HappyMessage {
  return {
    id: index === 0 ? base.id : `${base.id}:${index}`,
    localId: base.localId,
    seq: base.seq,
    createdAt: base.createdAt,
    role,
    kind,
    text: text.trim(),
    toolName,
    callId,
    isError,
  };
}

function summarizeToolOutput(output: Object | Object[] | string | null | undefined): string {
  let text: string;
  if (typeof output === 'string') {
    text = output.trim();
  } else if (Array.isArray(output)) {
    const parts: string[] = [];
    for (let index = 0; index < output.length; index += 1) {
      const item: Object = output[index];
      if (!Array.isArray(item)) {
        const textItem = item as AgentContentItemWire;
        if (textItem.type === 'text' && textItem.text) {
          parts.push(textItem.text);
        } else {
          parts.push(JSON.stringify(item));
        }
      } else {
        parts.push(JSON.stringify(item));
      }
    }
    text = parts.join('\n').trim();
  } else if (output === null || output === undefined) {
    text = '';
  } else {
    text = JSON.stringify(output);
  }
  if (text.length > TOOL_OUTPUT_MAX_LENGTH) {
    return `${text.substring(0, TOOL_OUTPUT_MAX_LENGTH - 3)}...`;
  }
  return text;
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

function parseMessagesResponse(text: string): Required<SessionMessagesWireEnvelope> {
  const parsed = JSON.parse(text) as SessionMessagesWireEnvelope;
  if (!parsed.messages || !Array.isArray(parsed.messages)) {
    throw new Error('消息列表响应格式不正确');
  }
  return {
    messages: parsed.messages,
    hasMore: parsed.hasMore === true,
  };
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

function encodePathSegment(value: string): string {
  return encodeURIComponent(value);
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
