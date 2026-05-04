export interface SessionMessagesCredentials {
  token: string;
  secretBase64Url: string;
}

export interface SessionMessageDecodeRequest {
  encrypted: string;
  dataEncryptionKey: string | null;
  credentials: SessionMessagesCredentials;
}

export type SessionMessageDecoder = (
  request: SessionMessageDecodeRequest,
) => Promise<unknown | null>;

export interface ApiSessionMessage {
  id: string;
  seq: number;
  content: unknown;
  localId?: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface ApiSessionMessagesResponse {
  messages?: ApiSessionMessage[];
  hasMore?: boolean;
}

export type SessionMessageRole = 'user' | 'agent' | 'system';
export type SessionMessageKind = 'text' | 'thinking' | 'tool-call' | 'tool-result' | 'service';

export interface SessionMessage {
  id: string;
  localId: string | null;
  seq: number;
  createdAt: number;
  role: SessionMessageRole;
  kind: SessionMessageKind;
  text: string;
  toolName?: string;
  callId?: string;
  isError?: boolean;
}

export interface SessionMessagesSnapshot {
  messages: SessionMessage[];
  lastSeq: number;
  decodeWarningCount: number;
}

export interface FetchSessionMessagesInput {
  sessionId: string;
  dataEncryptionKey: string | null;
  credentials: SessionMessagesCredentials;
  afterSeq?: number;
  limit?: number;
}

export interface SessionMessagesClient {
  fetchMessages(input: FetchSessionMessagesInput): Promise<SessionMessagesSnapshot>;
}

export interface SessionMessagesClientDependencies {
  getServerUrl(): string;
  getHappyClientId(): string;
  getJson<T>(url: string, headers: Record<string, string>): Promise<T>;
  decodeMessage: SessionMessageDecoder;
}

interface MessageBase {
  id: string;
  localId: string | null;
  seq: number;
  createdAt: number;
}

export function createSessionMessagesClient(dependencies: SessionMessagesClientDependencies): SessionMessagesClient {
  return {
    async fetchMessages(input) {
      if (input.credentials.token.length === 0) {
        throw new Error('Auth token is empty');
      }
      if (input.sessionId.trim().length === 0) {
        throw new Error('Session id is empty');
      }

      const serverUrl = trimTrailingSlashes(dependencies.getServerUrl());
      const headers = authHeaders(input.credentials.token, dependencies.getHappyClientId());
      const limit = input.limit ?? 100;
      let afterSeq = input.afterSeq ?? 0;
      let lastSeq = afterSeq;
      let hasMore = true;
      let decodeWarningCount = 0;
      const normalized: SessionMessage[] = [];

      while (hasMore) {
        const response = parseMessagesResponse(await dependencies.getJson<unknown>(
          `${serverUrl}/v3/sessions/${encodeURIComponent(input.sessionId)}/messages?after_seq=${afterSeq}&limit=${limit}`,
          headers,
        ));
        const messages = response.messages ?? [];
        let maxSeq = afterSeq;
        for (const message of messages) {
          if (message.seq > maxSeq) {
            maxSeq = message.seq;
          }

          const encrypted = getEncryptedContent(message.content);
          if (!encrypted) {
            decodeWarningCount += 1;
            continue;
          }
          const raw = await dependencies.decodeMessage({
            encrypted,
            dataEncryptionKey: input.dataEncryptionKey,
            credentials: input.credentials,
          });
          if (!raw) {
            decodeWarningCount += 1;
            continue;
          }
          normalized.push(...normalizeRawMessageRows({
            id: message.id,
            localId: message.localId ?? null,
            seq: message.seq,
            createdAt: message.createdAt,
          }, raw));
        }

        lastSeq = Math.max(lastSeq, maxSeq);
        hasMore = !!response.hasMore;
        if (hasMore && maxSeq === afterSeq) {
          break;
        }
        afterSeq = maxSeq;
      }

      return {
        messages: normalized,
        lastSeq,
        decodeWarningCount,
      };
    },
  };
}

export function formatMessagePreview(message: SessionMessage): string {
  if (message.kind === 'thinking') {
    return `思考：${message.text}`;
  }
  if (message.kind === 'tool-call') {
    return message.text;
  }
  if (message.kind === 'tool-result') {
    return message.text;
  }
  if (message.kind === 'service') {
    return `系统：${message.text}`;
  }
  return message.text;
}

export function normalizeRawMessageRows(base: MessageBase, raw: unknown): SessionMessage[] {
  if (!isRecord(raw)) {
    return [];
  }
  const role = raw.role;
  if (role === 'user') {
    return textRows(base, 'user', raw.content);
  }
  if (role === 'session') {
    return normalizeSessionEnvelope(base, isRecord(raw.content) ? raw.content : null);
  }
  if (role === 'agent') {
    return normalizeAgentContent(base, raw.content);
  }
  return [];
}

function normalizeAgentContent(base: MessageBase, content: unknown): SessionMessage[] {
  if (!isRecord(content)) {
    return [];
  }
  const type = content.type;
  if (type === 'codex') {
    return normalizeProviderEvent(base, content.data, 'codex');
  }
  if (type === 'acp') {
    return normalizeProviderEvent(base, content.data, `${content.provider ?? 'acp'}`);
  }
  if (type === 'session') {
    return normalizeSessionEnvelope(base, content.data);
  }
  if (type !== 'output' || !isRecord(content.data)) {
    return [];
  }

  const data = content.data;
  if (data.isMeta || data.isCompactSummary) {
    return [];
  }
  if (data.type === 'result') {
    return textRows(base, 'agent', data.result);
  }
  if (data.type === 'summary') {
    return textRows(base, 'agent', data.summary);
  }
  if (data.type === 'assistant' && isRecord(data.message)) {
    return contentRows(base, 'agent', data.message.content);
  }
  if (data.type === 'user' && isRecord(data.message)) {
    return contentRows(base, 'user', data.message.content);
  }
  return [];
}

function normalizeProviderEvent(base: MessageBase, data: unknown, provider: string): SessionMessage[] {
  if (!isRecord(data) || typeof data.type !== 'string') {
    return [];
  }
  if (data.type === 'message') {
    return textRows(base, 'agent', data.message);
  }
  if (data.type === 'reasoning') {
    return messageRows(base, [{
      role: 'agent',
      kind: 'thinking',
      text: asText(data.message),
    }]);
  }
  if (data.type === 'thinking') {
    return messageRows(base, [{
      role: 'agent',
      kind: 'thinking',
      text: asText(data.text),
    }]);
  }
  if (data.type === 'tool-call') {
    const toolName = asText(data.name) || 'unknown';
    return messageRows(base, [{
      role: 'agent',
      kind: 'tool-call',
      text: `调用工具：${toolName}`,
      toolName,
      callId: asText(data.callId || data.id),
    }]);
  }
  if (data.type === 'tool-result' || data.type === 'tool-call-result') {
    const output = data.output ?? data.content;
    return messageRows(base, [{
      role: 'agent',
      kind: 'tool-result',
      text: `工具结果：${summarizeToolOutput(output)}`,
      callId: asText(data.callId || data.id),
      isError: data.isError === true || data.is_error === true,
    }]);
  }
  if (data.type === 'permission-request') {
    const toolName = asText(data.toolName) || provider;
    return messageRows(base, [{
      role: 'agent',
      kind: 'tool-call',
      text: `权限请求：${toolName}`,
      toolName,
      callId: asText(data.permissionId),
    }]);
  }
  if (data.type === 'terminal-output') {
    return messageRows(base, [{
      role: 'agent',
      kind: 'tool-result',
      text: `工具结果：${summarizeToolOutput(data.data)}`,
      callId: asText(data.callId),
    }]);
  }
  if (data.type === 'file-edit') {
    return messageRows(base, [{
      role: 'agent',
      kind: 'tool-call',
      text: `调用工具：file-edit`,
      toolName: 'file-edit',
      callId: asText(data.id),
    }]);
  }
  return [];
}

function normalizeSessionEnvelope(base: MessageBase, envelope: unknown): SessionMessage[] {
  if (!isRecord(envelope)) {
    return [];
  }
  const inner = isRecord(envelope.data) ? envelope.data : envelope;
  if (!isRecord(inner.ev)) {
    return [];
  }
  const role: SessionMessageRole = inner.role === 'user' ? 'user' : 'agent';
  const event = inner.ev;
  if (event.t === 'text') {
    return messageRows(base, [{
      role,
      kind: event.thinking === true ? 'thinking' : 'text',
      text: asText(event.text),
    }]);
  }
  if (event.t === 'service') {
    return messageRows(base, [{
      role: 'system',
      kind: 'service',
      text: asText(event.text),
    }]);
  }
  if (event.t === 'tool-call-start') {
    const toolName = asText(event.name || event.title) || 'unknown';
    return messageRows(base, [{
      role: 'agent',
      kind: 'tool-call',
      text: `调用工具：${toolName}`,
      toolName,
      callId: asText(event.call),
    }]);
  }
  if (event.t === 'tool-call-end') {
    return messageRows(base, [{
      role: 'agent',
      kind: 'tool-result',
      text: '工具调用结束',
      callId: asText(event.call),
    }]);
  }
  if (event.t === 'file') {
    return messageRows(base, [{
      role,
      kind: 'tool-call',
      text: `文件：${asText(event.name)}`,
      toolName: 'file',
      callId: asText(event.ref),
    }]);
  }
  return [];
}

function contentRows(base: MessageBase, role: SessionMessageRole, content: unknown): SessionMessage[] {
  if (typeof content === 'string') {
    return textRows(base, role, content);
  }
  if (!Array.isArray(content)) {
    return [];
  }
  const partials: Array<Omit<SessionMessage, keyof MessageBase | 'localId' | 'seq' | 'createdAt' | 'id'>> = [];
  for (const item of content) {
    if (!isRecord(item) || typeof item.type !== 'string') {
      continue;
    }
    if (item.type === 'text') {
      partials.push({ role, kind: 'text', text: asText(item.text) });
    } else if (item.type === 'thinking') {
      partials.push({ role: 'agent', kind: 'thinking', text: asText(item.thinking) });
    } else if (item.type === 'tool_use' || item.type === 'tool-call') {
      const toolName = asText(item.name) || 'unknown';
      partials.push({
        role: 'agent',
        kind: 'tool-call',
        text: `调用工具：${toolName}`,
        toolName,
        callId: asText(item.id || item.callId),
      });
    } else if (item.type === 'tool_result' || item.type === 'tool-call-result') {
      partials.push({
        role: 'agent',
        kind: 'tool-result',
        text: `工具结果：${summarizeToolOutput(item.content ?? item.output)}`,
        callId: asText(item.tool_use_id || item.callId),
        isError: item.is_error === true || item.isError === true,
      });
    }
  }
  return messageRows(base, partials);
}

function textRows(base: MessageBase, role: SessionMessageRole, content: unknown): SessionMessage[] {
  if (typeof content === 'string') {
    return messageRows(base, [{ role, kind: 'text', text: content }]);
  }
  if (isRecord(content) && content.type === 'text') {
    return messageRows(base, [{ role, kind: 'text', text: asText(content.text) }]);
  }
  if (Array.isArray(content)) {
    return contentRows(base, role, content);
  }
  return [];
}

function messageRows(
  base: MessageBase,
  partials: Array<Omit<SessionMessage, keyof MessageBase | 'localId' | 'seq' | 'createdAt' | 'id'>>,
): SessionMessage[] {
  const rows = partials.filter((message) => message.text.trim().length > 0);
  return rows.map((message, index) => ({
    id: rows.length === 1 ? base.id : `${base.id}:${index}`,
    localId: base.localId,
    seq: base.seq,
    createdAt: base.createdAt,
    ...message,
    text: message.text.trim(),
  }));
}

function summarizeToolOutput(output: unknown): string {
  if (typeof output === 'string') {
    return truncate(output.trim());
  }
  if (Array.isArray(output)) {
    const text = output.map((item) => {
      if (isRecord(item) && typeof item.text === 'string') {
        return item.text;
      }
      return asText(item);
    }).filter(Boolean).join('\n');
    return truncate(text || JSON.stringify(output));
  }
  return truncate(asText(output));
}

function getEncryptedContent(content: unknown): string | null {
  if (!isRecord(content) || content.t !== 'encrypted' || typeof content.c !== 'string') {
    return null;
  }
  return content.c;
}

function parseMessagesResponse(value: unknown): Required<ApiSessionMessagesResponse> {
  if (!isRecord(value) || !Array.isArray(value.messages)) {
    throw new Error('Session messages response has an invalid shape');
  }
  return {
    messages: value.messages as ApiSessionMessage[],
    hasMore: value.hasMore === true,
  };
}

function authHeaders(token: string, happyClient: string): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
    'X-Happy-Client': happyClient,
  };
}

function trimTrailingSlashes(url: string): string {
  let trimmed = url.trim();
  while (trimmed.length > 'https://'.length && trimmed.endsWith('/')) {
    trimmed = trimmed.slice(0, -1);
  }
  return trimmed;
}

function asText(value: unknown): string {
  if (typeof value === 'string') {
    return value;
  }
  if (value === null || value === undefined) {
    return '';
  }
  try {
    return JSON.stringify(value);
  } catch {
    return `${value}`;
  }
}

function truncate(value: string): string {
  return value.length > 240 ? `${value.slice(0, 237)}...` : value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
