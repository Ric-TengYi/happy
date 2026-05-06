import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { Credentials, loadCredentials } from './HappyAuth';
import { HappySession } from './HappySync';
import { decryptBoxBundle, decryptSecretBox, deriveContentSecretKey, encryptSecretBox } from './HappyBox';

const HAPPY_CLIENT_ID: string = 'harmony/0.1.0';
const BASE64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const ACCOUNT_SECRET_LENGTH: number = 32;
const DATA_KEY_LENGTH: number = 32;
const AES_GCM_VERSION: number = 0;
const AES_GCM_NONCE_LENGTH: number = 12;
const AES_GCM_AUTH_TAG_LENGTH: number = 16;
const PAGE_LIMIT: number = 100;
const TOOL_OUTPUT_MAX_LENGTH: number = 240;
const APPEND_SYSTEM_PROMPT: string = `# Options

You have a way to give a user a easy way to answer your questions if you know possible answers. To provide this, you need to output in your final response an XML:

<options>
    <option>Option 1</option>
    ...
    <option>Option N</option>
</options>

You must output this in the very end of your response, not inside of any other text. Do not wrap it into a codeblock. Always dedicate "<options>" and "</options>" to a dedicated line. Never output anything like "custom", user always have an option to send a custom message. Do not enumerate options in both text and options block.
Always prefer to use the options mode to the text mode. Try to keep options minimal, better to clarify in a next steps.

# Plan mode with options

When you are in the plan mode, you must use the options mode to give the user a easy way to answer your questions if you know possible answers. Do not assume what is needed, when there is discrepancy between what you need and what you have, you must use the options mode.`;

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

interface SentSessionMessageWire {
  id: string;
  seq: number;
  localId?: string | null;
  createdAt: number;
  updatedAt: number;
}

interface SendSessionMessagesWireEnvelope {
  messages?: SentSessionMessageWire[];
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

interface RawUserTextContent {
  type: string;
  text: string;
}

interface RawUserTextMeta {
  sentFrom: string;
  permissionMode: string;
  model: string | null;
  fallbackModel: string | null;
  appendSystemPrompt: string;
}

interface RawUserTextRecord {
  role: string;
  content: RawUserTextContent;
  meta: RawUserTextMeta;
}

interface MessageModeMeta {
  permissionMode: string;
  model: string | null;
}

interface SendRequestMessage {
  localId: string;
  content: string;
}

interface SendRequestBody {
  messages: SendRequestMessage[];
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

interface PermissionStateWire {
  tool?: string;
  arguments?: Object | Object[] | string | number | boolean | null;
  createdAt?: number | null;
  completedAt?: number | null;
  status?: string;
  reason?: string | null;
  mode?: string | null;
  allowedTools?: string[] | null;
  allowTools?: string[] | null;
  decision?: string | null;
}

interface AgentStateWire {
  requests?: Record<string, PermissionStateWire> | null;
  completedRequests?: Record<string, PermissionStateWire> | null;
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

export interface HappyPermission {
  id: string;
  toolName: string;
  status: string;
  argumentsText: string;
  argumentsJson: string;
  createdAt: number;
  reason: string;
  mode: string;
  decision: string;
  allowedTools: string[];
}

export interface SessionMessagesSnapshot {
  messages: HappyMessage[];
  permissions: HappyPermission[];
  lastSeq: number;
  decodeWarningCount: number;
}

export interface SentSessionMessage {
  id: string;
  seq: number;
  localId: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface SendSessionMessageResult {
  localId: string;
  optimisticMessage: HappyMessage;
  responseMessages: SentSessionMessage[];
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
      http.RequestMethod.GET,
      undefined,
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
    permissions: extractSessionPermissions(session.agentState),
    lastSeq,
    decodeWarningCount: decodeStats.failures,
  };
}

export async function sendSessionTextMessage(
  context: common.UIAbilityContext,
  serverUrl: string,
  session: HappySession,
  text: string,
  localId: string,
  createdAt: number,
): Promise<SendSessionMessageResult> {
  const trimmedText = text.trim();
  if (trimmedText.length === 0) {
    throw new Error('请输入消息内容');
  }
  if (localId.length === 0) {
    throw new Error('本地消息 ID 为空');
  }

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

  const modeMeta = resolveMessageModeMeta(session);
  const record = buildRawUserTextRecord(trimmedText, modeMeta);
  const encrypted = encryptRawRecord(record, cipher);
  const body: SendRequestBody = {
    messages: [{
      localId,
      content: encrypted,
    }],
  };
  const headers: AuthHeaders = {
    'Authorization': `Bearer ${credentials.token}`,
    'Content-Type': 'application/json',
    'X-Happy-Client': HAPPY_CLIENT_ID,
  };
  const response = await requestText(
    `${normalizeServerUrl(serverUrl)}/v3/sessions/${encodePathSegment(session.id)}/messages`,
    http.RequestMethod.POST,
    JSON.stringify(body),
    headers,
  );
  if (!response.ok) {
    throw new Error(`发送消息失败：${response.statusCode}`);
  }

  return {
    localId,
    optimisticMessage: createOptimisticUserMessage(localId, trimmedText, createdAt),
    responseMessages: parseSendMessagesResponse(response.text),
  };
}

export function createOptimisticUserMessage(localId: string, text: string, createdAt: number): HappyMessage {
  return makeMessage({
    id: localId,
    localId,
    seq: 0,
    createdAt,
  }, 0, 'user', 'text', text, '', '', false);
}

export function encryptSessionRawPayload(value: Object, session: HappySession, credentials: Credentials): string {
  return encryptRawPayload(value, session.dataEncryptionKey, credentials, '会话密钥不可用');
}

export function encryptRawPayload(
  value: Object,
  dataEncryptionKey: string | null,
  credentials: Credentials,
  missingKeyMessage: string = '数据密钥不可用',
): string {
  const cipher = resolveRecordCipher(dataEncryptionKey, credentials);
  if (!cipher) {
    throw new Error(missingKeyMessage);
  }
  return encryptRawJson(value, cipher);
}

export function decryptRawPayload(
  encryptedText: string,
  dataEncryptionKey: string | null,
  credentials: Credentials,
  missingKeyMessage: string = '数据密钥不可用',
): Object {
  const cipher = resolveRecordCipher(dataEncryptionKey, credentials);
  if (!cipher) {
    throw new Error(missingKeyMessage);
  }
  try {
    const encryptedBytes = decodeBase64(encryptedText);
    const plain = cipher.isDataKey ? decryptAesGcm(encryptedBytes, cipher.key) : decryptSecretBox(encryptedBytes, cipher.key);
    if (!plain) {
      throw new Error('解密结果为空');
    }
    const parsed = JSON.parse(bytesToUtf8String(plain)) as Object;
    if (typeof parsed === 'object' && parsed !== null) {
      return parsed;
    }
    throw new Error('解密结果格式不正确');
  } catch (error) {
    console.error(`数据解密失败：${error}`);
    throw new Error('数据解密失败');
  }
}

export function createLocalMessageId(): string {
  const bytes = randomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  return `${hexBytes(bytes, 0, 4)}-${hexBytes(bytes, 4, 6)}-${hexBytes(bytes, 6, 8)}-${hexBytes(bytes, 8, 10)}-${hexBytes(bytes, 10, 16)}`;
}

function buildRawUserTextRecord(text: string, modeMeta: MessageModeMeta): RawUserTextRecord {
  return {
    role: 'user',
    content: {
      type: 'text',
      text,
    },
    meta: {
      sentFrom: 'harmony',
      permissionMode: modeMeta.permissionMode,
      model: modeMeta.model,
      fallbackModel: null,
      appendSystemPrompt: APPEND_SYSTEM_PROMPT,
    },
  };
}

function resolveMessageModeMeta(session: HappySession): MessageModeMeta {
  const explicitPermissionMode = normalizeOptionalText(session.permissionMode);
  let permissionMode = 'default';
  if (explicitPermissionMode.length > 0) {
    permissionMode = explicitPermissionMode;
  } else {
    const metadataPermissionMode = normalizeOptionalText(session.metadata?.currentOperatingModeCode);
    permissionMode = isMessagePermissionMode(metadataPermissionMode)
      ? metadataPermissionMode
      : (isSessionSandboxEnabled(session) ? 'bypassPermissions' : 'default');
  }
  const modelMode = normalizeOptionalText(session.modelMode);
  const metadataModelMode = normalizeOptionalText(session.metadata?.currentModelCode);
  return {
    permissionMode,
    model: modelMode.length > 0
      ? (modelMode !== 'default' ? modelMode : null)
      : (metadataModelMode.length > 0 && metadataModelMode !== 'default' ? metadataModelMode : null),
  };
}

function isSessionSandboxEnabled(session: HappySession): boolean {
  return session.metadata?.sandbox?.enabled === true;
}

function isMessagePermissionMode(value: string): boolean {
  return value === 'acceptEdits'
    || value === 'bypassPermissions'
    || value === 'plan'
    || value === 'read-only'
    || value === 'safe-yolo'
    || value === 'yolo';
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

function encryptRawRecord(record: RawUserTextRecord, cipher: RecordCipher): string {
  return encryptRawJson(record, cipher);
}

function encryptRawJson(value: Object, cipher: RecordCipher): string {
  const plain = utf8StringToBytes(JSON.stringify(value));
  const encrypted = cipher.isDataKey ? encryptAesGcm(plain, cipher.key) : encryptSecretBox(plain, cipher.key);
  return encodeBase64(encrypted);
}

function extractSessionPermissions(agentState: Object | null): HappyPermission[] {
  if (!agentState) {
    return [];
  }
  const state = agentState as AgentStateWire;
  const permissions: HappyPermission[] = [];
  const completed = state.completedRequests;
  if (state.requests) {
    const requestIds = Object.keys(state.requests);
    for (const id of requestIds) {
      if (completed && completed[id]) {
        continue;
      }
      permissions.push(makePermission(id, state.requests[id], 'pending'));
    }
  }
  if (completed) {
    const completedIds = Object.keys(completed);
    for (const id of completedIds) {
      permissions.push(makePermission(id, completed[id], normalizeOptionalText(completed[id].status) || 'completed'));
    }
  }
  permissions.sort((left: HappyPermission, right: HappyPermission): number => left.createdAt - right.createdAt);
  return permissions;
}

function makePermission(id: string, wire: PermissionStateWire, fallbackStatus: string): HappyPermission {
  const allowedTools = wire.allowedTools ?? wire.allowTools ?? [];
  const argumentsJson = stringifyPermissionArguments(wire.arguments);
  return {
    id,
    toolName: normalizeOptionalText(wire.tool) || '工具调用',
    status: normalizeOptionalText(wire.status) || fallbackStatus,
    argumentsText: truncateText(argumentsJson),
    argumentsJson,
    createdAt: typeof wire.createdAt === 'number' ? wire.createdAt : Date.now(),
    reason: normalizeOptionalText(wire.reason),
    mode: normalizeOptionalText(wire.mode),
    decision: normalizeOptionalText(wire.decision),
    allowedTools,
  };
}

function summarizePermissionArguments(value: Object | Object[] | string | number | boolean | null | undefined): string {
  return truncateText(stringifyPermissionArguments(value));
}

function stringifyPermissionArguments(value: Object | Object[] | string | number | boolean | null | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return `${value}`;
  }
  try {
    return JSON.stringify(value);
  } catch {
    return '';
  }
}

function truncateText(value: string): string {
  if (value.length > TOOL_OUTPUT_MAX_LENGTH) {
    return `${value.substring(0, TOOL_OUTPUT_MAX_LENGTH - 3)}...`;
  }
  return value;
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

function encryptAesGcm(plain: Uint8Array, keyBytes: Uint8Array): Uint8Array {
  const nonce = randomBytes(AES_GCM_NONCE_LENGTH);
  const key = cryptoFramework.createSymKeyGenerator('AES256').convertKeySync({ data: keyBytes });
  const cipher = cryptoFramework.createCipher('AES256|GCM|PKCS7');
  const params: cryptoFramework.GcmParamsSpec = {
    iv: { data: nonce },
    aad: { data: new Uint8Array() },
    authTag: { data: new Uint8Array() },
    algName: 'GcmParamsSpec',
  };
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, params);
  const encrypted = cipher.doFinalSync({ data: plain }).data;
  const directBundle = buildAesGcmBundle(nonce, encrypted);
  if (decryptAesGcm(directBundle, keyBytes)) {
    return directBundle;
  }
  if (params.authTag.data.length > 0) {
    const combined = concatBytes(encrypted, params.authTag.data);
    const taggedBundle = buildAesGcmBundle(nonce, combined);
    if (decryptAesGcm(taggedBundle, keyBytes)) {
      return taggedBundle;
    }
  }
  throw new Error('AES-GCM 加密结果校验失败');
}

function buildAesGcmBundle(nonce: Uint8Array, encryptedWithTag: Uint8Array): Uint8Array {
  const bundle = new Uint8Array(1 + nonce.length + encryptedWithTag.length);
  bundle[0] = AES_GCM_VERSION;
  bundle.set(nonce, 1);
  bundle.set(encryptedWithTag, 1 + nonce.length);
  return bundle;
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

function parseSendMessagesResponse(text: string): SentSessionMessage[] {
  const parsed = JSON.parse(text) as SendSessionMessagesWireEnvelope;
  if (!parsed.messages || !Array.isArray(parsed.messages)) {
    throw new Error('发送消息响应格式不正确');
  }
  return parsed.messages.map((message: SentSessionMessageWire): SentSessionMessage => {
    return {
      id: message.id,
      seq: message.seq,
      localId: message.localId ?? null,
      createdAt: message.createdAt,
      updatedAt: message.updatedAt,
    };
  });
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

function normalizeServerUrl(url: string): string {
  let normalized = url.trim();
  while (normalized.length > 'https://'.length && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

function randomBytes(length: number): Uint8Array {
  return cryptoFramework.createRandom().generateRandomSync(length).data;
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

function hexBytes(bytes: Uint8Array, start: number, end: number): string {
  let value = '';
  for (let index = start; index < end; index += 1) {
    value += bytes[index].toString(16).padStart(2, '0');
  }
  return value;
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

function utf8StringToBytes(value: string): Uint8Array {
  const encoded = buffer.from(value, 'utf8');
  const bytes = new Uint8Array(encoded.length);
  for (let index = 0; index < encoded.length; index += 1) {
    bytes[index] = encoded[index];
  }
  return bytes;
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
