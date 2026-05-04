import { describe, expect, it } from 'vitest';
import {
  DEFAULT_APPEND_SYSTEM_PROMPT,
  createOptimisticUserMessage,
  createSessionMessagesClient,
  formatMessagePreview,
  type RawUserTextRecord,
  type SessionMessageDecodeRequest,
  type SessionMessagesCredentials,
} from './sessionMessages';

const credentials: SessionMessagesCredentials = {
  token: 'happy-token',
  secretBase64Url: 'secret',
};

describe('session messages client', () => {
  it('fetches messages with Happy auth headers and paginates until the server has no more rows', async () => {
    const requests: Array<{ url: string; headers: Record<string, string> }> = [];
    const decodeRequests: SessionMessageDecodeRequest[] = [];
    const client = createSessionMessagesClient({
      getServerUrl: () => 'https://happy.example.com/',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(url: string, headers: Record<string, string>): Promise<T> => {
        requests.push({ url, headers });
        if (url.endsWith('after_seq=0&limit=100')) {
          return {
            messages: [
              {
                id: 'msg-1',
                seq: 3,
                content: { t: 'encrypted', c: 'encrypted-user' },
                localId: 'local-1',
                createdAt: 1000,
                updatedAt: 1001,
              },
            ],
            hasMore: true,
          } as T;
        }
        return {
          messages: [
            {
              id: 'msg-2',
              seq: 5,
              content: { t: 'encrypted', c: 'encrypted-agent' },
              localId: null,
              createdAt: 2000,
              updatedAt: 2001,
            },
          ],
          hasMore: false,
        } as T;
      },
      decodeMessage: async (request) => {
        decodeRequests.push(request);
        if (request.encrypted === 'encrypted-user') {
          return {
            role: 'user',
            content: '继续模块 5',
          };
        }
        return {
          role: 'agent',
          content: {
            type: 'codex',
            data: { type: 'message', message: '收到，开始读取消息' },
          },
        };
      },
    });

    const snapshot = await client.fetchMessages({
      sessionId: 'session-1',
      dataEncryptionKey: 'session-data-key',
      credentials,
    });

    expect(requests).toEqual([
      {
        url: 'https://happy.example.com/v3/sessions/session-1/messages?after_seq=0&limit=100',
        headers: {
          Authorization: 'Bearer happy-token',
          'Content-Type': 'application/json',
          'X-Happy-Client': 'harmony/0.1.0',
        },
      },
      {
        url: 'https://happy.example.com/v3/sessions/session-1/messages?after_seq=3&limit=100',
        headers: {
          Authorization: 'Bearer happy-token',
          'Content-Type': 'application/json',
          'X-Happy-Client': 'harmony/0.1.0',
        },
      },
    ]);
    expect(decodeRequests).toEqual([
      {
        encrypted: 'encrypted-user',
        dataEncryptionKey: 'session-data-key',
        credentials,
      },
      {
        encrypted: 'encrypted-agent',
        dataEncryptionKey: 'session-data-key',
        credentials,
      },
    ]);
    expect(snapshot.lastSeq).toBe(5);
    expect(snapshot.messages).toEqual([
      {
        id: 'msg-1',
        localId: 'local-1',
        seq: 3,
        createdAt: 1000,
        role: 'user',
        kind: 'text',
        text: '继续模块 5',
      },
      {
        id: 'msg-2',
        localId: null,
        seq: 5,
        createdAt: 2000,
        role: 'agent',
        kind: 'text',
        text: '收到，开始读取消息',
      },
    ]);
  });

  it('normalizes Codex reasoning and tool events into compact Harmony rows', async () => {
    const client = createSessionMessagesClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(): Promise<T> => ({
        messages: [
          {
            id: 'msg-1',
            seq: 1,
            content: { t: 'encrypted', c: 'reasoning' },
            localId: null,
            createdAt: 1000,
            updatedAt: 1000,
          },
          {
            id: 'msg-2',
            seq: 2,
            content: { t: 'encrypted', c: 'tool-call' },
            localId: null,
            createdAt: 1100,
            updatedAt: 1100,
          },
          {
            id: 'msg-3',
            seq: 3,
            content: { t: 'encrypted', c: 'tool-result' },
            localId: null,
            createdAt: 1200,
            updatedAt: 1200,
          },
        ],
        hasMore: false,
      }) as T,
      decodeMessage: async (request) => {
        if (request.encrypted === 'reasoning') {
          return {
            role: 'agent',
            content: {
              type: 'codex',
              data: { type: 'reasoning', message: '需要先读取会话协议' },
            },
          };
        }
        if (request.encrypted === 'tool-call') {
          return {
            role: 'agent',
            content: {
              type: 'codex',
              data: { type: 'tool-call', callId: 'call-1', id: 'tool-1', name: 'Read', input: { file_path: '/tmp/a.ts' } },
            },
          };
        }
        return {
          role: 'agent',
          content: {
            type: 'codex',
            data: { type: 'tool-call-result', callId: 'call-1', id: 'tool-2', output: '读取完成' },
          },
        };
      },
    });

    const snapshot = await client.fetchMessages({
      sessionId: 'session-1',
      dataEncryptionKey: null,
      credentials,
    });

    expect(snapshot.messages).toEqual([
      expect.objectContaining({
        kind: 'thinking',
        role: 'agent',
        text: '需要先读取会话协议',
      }),
      expect.objectContaining({
        kind: 'tool-call',
        role: 'agent',
        text: '调用工具：Read',
      }),
      expect.objectContaining({
        kind: 'tool-result',
        role: 'agent',
        text: '工具结果：读取完成',
      }),
    ]);
    expect(snapshot.messages.map(formatMessagePreview)).toEqual([
      '思考：需要先读取会话协议',
      '调用工具：Read',
      '工具结果：读取完成',
    ]);
  });

  it('normalizes Android-compatible user text objects and Claude tool result text arrays', async () => {
    const client = createSessionMessagesClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(url: string): Promise<T> => {
        expect(url).toBe('https://happy.example.com/v3/sessions/session%2Fwith%3Fchars/messages?after_seq=0&limit=100');
        return {
          messages: [
            {
              id: 'msg-1',
              seq: 1,
              content: { t: 'encrypted', c: 'user-object' },
              localId: null,
              createdAt: 1000,
              updatedAt: 1000,
            },
            {
              id: 'msg-2',
              seq: 2,
              content: { t: 'encrypted', c: 'tool-array' },
              localId: null,
              createdAt: 1100,
              updatedAt: 1100,
            },
          ],
          hasMore: false,
        } as T;
      },
      decodeMessage: async (request) => {
        if (request.encrypted === 'user-object') {
          return {
            role: 'user',
            content: { type: 'text', text: '这是用户输入' },
          };
        }
        return {
          role: 'agent',
          content: {
            type: 'output',
            data: {
              type: 'assistant',
              message: {
                content: [
                  {
                    type: 'tool_result',
                    tool_use_id: 'call-1',
                    content: [{ type: 'text', text: '第一行' }, { type: 'text', text: '第二行' }],
                  },
                ],
              },
            },
          },
        };
      },
    });

    const snapshot = await client.fetchMessages({
      sessionId: 'session/with?chars',
      dataEncryptionKey: null,
      credentials,
    });

    expect(snapshot.messages).toEqual([
      expect.objectContaining({
        role: 'user',
        kind: 'text',
        text: '这是用户输入',
      }),
      expect.objectContaining({
        role: 'agent',
        kind: 'tool-result',
        text: '工具结果：第一行\n第二行',
      }),
    ]);
  });

  it('stops pagination when the server returns hasMore without advancing seq', async () => {
    let requestCount = 0;
    const client = createSessionMessagesClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(): Promise<T> => {
        requestCount += 1;
        return {
          messages: [],
          hasMore: true,
        } as T;
      },
      decodeMessage: async () => null,
    });

    const snapshot = await client.fetchMessages({
      sessionId: 'session-1',
      dataEncryptionKey: null,
      credentials,
    });

    expect(requestCount).toBe(1);
    expect(snapshot).toEqual({ messages: [], lastSeq: 0, decodeWarningCount: 0 });
  });

  it('counts malformed or undecryptable messages without stopping the page', async () => {
    const client = createSessionMessagesClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(): Promise<T> => ({
        messages: [
          {
            id: 'msg-1',
            seq: 1,
            content: { t: 'plain', c: 'not-encrypted' },
            localId: null,
            createdAt: 1000,
            updatedAt: 1000,
          },
          {
            id: 'msg-2',
            seq: 2,
            content: { t: 'encrypted', c: 'missing-key' },
            localId: null,
            createdAt: 1100,
            updatedAt: 1100,
          },
          {
            id: 'msg-3',
            seq: 3,
            content: { t: 'encrypted', c: 'valid' },
            localId: null,
            createdAt: 1200,
            updatedAt: 1200,
          },
        ],
        hasMore: false,
      }) as T,
      decodeMessage: async (request) => {
        if (request.encrypted === 'valid') {
          return { role: 'user', content: '能正常显示' };
        }
        return null;
      },
    });

    const snapshot = await client.fetchMessages({
      sessionId: 'session-1',
      dataEncryptionKey: null,
      credentials,
    });

    expect(snapshot.decodeWarningCount).toBe(2);
    expect(snapshot.lastSeq).toBe(3);
    expect(snapshot.messages).toEqual([
      expect.objectContaining({ id: 'msg-3', role: 'user', text: '能正常显示' }),
    ]);
  });

  it('sends an Android-compatible encrypted user text record with localId idempotency', async () => {
    const encryptedRecords: Array<{ record: RawUserTextRecord; dataEncryptionKey: string | null }> = [];
    const posts: Array<{ url: string; headers: Record<string, string>; body: unknown }> = [];
    const client = createSessionMessagesClient({
      getServerUrl: () => 'https://happy.example.com/',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(): Promise<T> => {
        throw new Error('GET should not be used while sending');
      },
      decodeMessage: async () => null,
      encryptMessage: async (request) => {
        encryptedRecords.push({
          record: request.record,
          dataEncryptionKey: request.dataEncryptionKey,
        });
        return 'encrypted-user-record';
      },
      postJson: async <T>(url: string, headers: Record<string, string>, body: unknown): Promise<T> => {
        posts.push({ url, headers, body });
        return {
          messages: [
            {
              id: 'server-msg-1',
              seq: 12,
              localId: 'local-123',
              createdAt: 3000,
              updatedAt: 3001,
            },
          ],
        } as T;
      },
      createLocalId: () => 'local-123',
      now: () => 2500,
    });

    const result = await client.sendMessage({
      sessionId: 'session/1',
      dataEncryptionKey: 'session-data-key',
      credentials,
      text: '继续实现模块 6',
      permissionMode: 'default',
      model: null,
      appendSystemPrompt: '# Options',
    });

    expect(encryptedRecords).toEqual([
      {
        dataEncryptionKey: 'session-data-key',
        record: {
          role: 'user',
          content: {
            type: 'text',
            text: '继续实现模块 6',
          },
          meta: {
            sentFrom: 'harmony',
            permissionMode: 'default',
            model: null,
            fallbackModel: null,
            appendSystemPrompt: '# Options',
          },
        },
      },
    ]);
    expect(posts).toEqual([
      {
        url: 'https://happy.example.com/v3/sessions/session%2F1/messages',
        headers: {
          Authorization: 'Bearer happy-token',
          'Content-Type': 'application/json',
          'X-Happy-Client': 'harmony/0.1.0',
        },
        body: {
          messages: [
            {
              localId: 'local-123',
              content: 'encrypted-user-record',
            },
          ],
        },
      },
    ]);
    expect(result.localMessage).toEqual({
      id: 'local-123',
      localId: 'local-123',
      seq: 0,
      createdAt: 2500,
      role: 'user',
      kind: 'text',
      text: '继续实现模块 6',
    });
    expect(result.responseMessages).toEqual([
      {
        id: 'server-msg-1',
        seq: 12,
        localId: 'local-123',
        createdAt: 3000,
        updatedAt: 3001,
      },
    ]);
  });

  it('rejects empty send text before encryption or POST', async () => {
    let encrypted = false;
    let posted = false;
    const client = createSessionMessagesClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(): Promise<T> => ({} as T),
      decodeMessage: async () => null,
      encryptMessage: async () => {
        encrypted = true;
        return 'encrypted';
      },
      postJson: async <T>(): Promise<T> => {
        posted = true;
        return {} as T;
      },
    });

    await expect(client.sendMessage({
      sessionId: 'session-1',
      dataEncryptionKey: null,
      credentials,
      text: '   ',
    })).rejects.toThrow('Message text is empty');
    expect(encrypted).toBe(false);
    expect(posted).toBe(false);
  });

  it('uses the Android append system prompt by default when sending', async () => {
    const encryptedRecords: RawUserTextRecord[] = [];
    const client = createSessionMessagesClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(): Promise<T> => ({} as T),
      decodeMessage: async () => null,
      encryptMessage: async (request) => {
        encryptedRecords.push(request.record);
        return 'encrypted';
      },
      postJson: async <T>(): Promise<T> => ({
        messages: [{
          id: 'server-msg-1',
          seq: 1,
          localId: 'local-1',
          createdAt: 1,
          updatedAt: 1,
        }],
      } as T),
      createLocalId: () => 'local-1',
      now: () => 1,
    });

    await client.sendMessage({
      sessionId: 'session-1',
      dataEncryptionKey: null,
      credentials,
      text: '默认提示',
    });

    expect(encryptedRecords[0]?.meta.appendSystemPrompt).toBe(DEFAULT_APPEND_SYSTEM_PROMPT);
  });

  it('creates an optimistic local user message with the localId as its stable id', () => {
    expect(createOptimisticUserMessage({
      localId: 'local-1',
      text: '本地先显示',
      createdAt: 4000,
    })).toEqual({
      id: 'local-1',
      localId: 'local-1',
      seq: 0,
      createdAt: 4000,
      role: 'user',
      kind: 'text',
      text: '本地先显示',
    });
  });
});
