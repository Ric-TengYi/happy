import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { webSocket } from '@kit.NetworkKit';
import { Credentials, loadCredentials } from './HappyAuth';
import { HappySession } from './HappySync';
import { HappyPermission, encryptSessionRawPayload } from './HappyMessages';

const HAPPY_CLIENT_ID: string = 'harmony/0.1.0';
const SOCKET_PATH: string = '/v1/updates/';
const RPC_ACK_ID: number = 1;
const RPC_TIMEOUT_MS: number = 12000;

interface WebSocketHeaders {
  'X-Happy-Client': string;
}

interface SocketAuthBody {
  token: string;
  clientType: string;
  happyClient: string;
}

interface RpcCallBody {
  method: string;
  params: string;
}

interface RpcAckWire {
  ok?: boolean;
  result?: string;
  error?: string;
}

interface SessionPermissionRequest {
  id: string;
  approved: boolean;
  mode?: string;
  allowTools?: string[];
  decision?: string;
}

export type PermissionAction = 'allow' | 'allowForSession' | 'allowAllEdits' | 'allowEverything' | 'deny';

export async function respondToSessionPermission(
  context: common.UIAbilityContext,
  serverUrl: string,
  session: HappySession,
  permission: HappyPermission,
  action: PermissionAction,
): Promise<void> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (permission.id.length === 0) {
    throw new Error('权限请求 ID 为空');
  }

  const request = buildPermissionRequest(session, permission, action);
  const encryptedParams = encryptSessionRawPayload(request, session, credentials);
  await sendSessionRpc(serverUrl, credentials, `${session.id}:permission`, encryptedParams);
}

function buildPermissionRequest(session: HappySession, permission: HappyPermission, action: PermissionAction): SessionPermissionRequest {
  const usesDecision = usesDecisionPermission(session, permission);
  if (action === 'allow') {
    return {
      id: permission.id,
      approved: true,
      decision: usesDecision ? 'approved' : undefined,
    };
  }
  if (action === 'allowForSession') {
    if (usesDecision) {
      return {
        id: permission.id,
        approved: true,
        decision: 'approved_for_session',
      };
    }
    return {
      id: permission.id,
      approved: true,
      allowTools: [buildToolIdentifier(permission)],
    };
  }
  if (action === 'allowAllEdits') {
    return {
      id: permission.id,
      approved: true,
      mode: 'acceptEdits',
    };
  }
  if (action === 'allowEverything') {
    return {
      id: permission.id,
      approved: true,
      mode: 'bypassPermissions',
    };
  }
  return {
    id: permission.id,
    approved: false,
    decision: usesDecision ? 'abort' : undefined,
  };
}

function usesDecisionPermission(session: HappySession, permission: HappyPermission): boolean {
  return !isClaudeSession(session) || permission.toolName.startsWith('Codex');
}

function isClaudeSession(session: HappySession): boolean {
  const flavor = session.metadata?.flavor;
  return !flavor || flavor === 'claude';
}

function buildToolIdentifier(permission: HappyPermission): string {
  if (permission.toolName === 'Bash') {
    const command = extractCommand(permission.argumentsJson);
    if (command.length > 0) {
      return `Bash(${command})`;
    }
  }
  return permission.toolName;
}

function extractCommand(argumentsText: string): string {
  try {
    const parsed = JSON.parse(argumentsText) as Object;
    const record = parsed as Record<string, Object>;
    const command = record['command'];
    return typeof command === 'string' ? command : '';
  } catch {
    return '';
  }
}

function sendSessionRpc(serverUrl: string, credentials: Credentials, method: string, encryptedParams: string): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    let done = false;
    let authenticated = false;
    const socket = webSocket.createWebSocket();
    const timerId = setTimeout((): void => {
      finishWithError(socket, '权限请求超时');
    }, RPC_TIMEOUT_MS);

    const finish = (error: Error | null): void => {
      if (done) {
        return;
      }
      done = true;
      clearTimeout(timerId);
      try {
        socket.off('open');
        socket.off('message');
        socket.off('close');
        socket.off('error');
        socket.close({ code: 1000, reason: 'rpc done' }).catch((closeError: BusinessError) => {
          console.error(`权限 RPC 关闭失败：${closeError}`);
        });
      } catch (closeError) {
        console.error(`权限 RPC 关闭失败：${closeError}`);
      }
      if (error) {
        reject(error);
      } else {
        resolve();
      }
    };

    const finishWithError = (_socket: webSocket.WebSocket, message: string): void => {
      finish(new Error(message));
    };

    const sendText = (text: string): void => {
      socket.send(text).catch((error: BusinessError) => {
        finish(new Error(`权限 RPC 发送失败：${error}`));
      });
    };

    socket.on('message', (error: BusinessError, data: string | ArrayBuffer): void => {
      if (done) {
        return;
      }
      if (error) {
        finish(new Error(`权限 RPC 接收失败：${error}`));
        return;
      }
      const packet = socketMessageToString(data);
      if (packet.startsWith('0')) {
        sendText(buildSocketAuthPacket(credentials.token));
      } else if (packet === '2') {
        sendText('3');
      } else if (packet.startsWith('40')) {
        if (!authenticated) {
          authenticated = true;
          sendText(buildRpcCallPacket(RPC_ACK_ID, {
            method,
            params: encryptedParams,
          }));
        }
      } else if (packet.startsWith('44')) {
        finish(new Error('权限 RPC 鉴权失败'));
      } else {
        const ack = parseRpcAck(packet, RPC_ACK_ID);
        if (ack) {
          if (ack.ok === true) {
            finish(null);
          } else {
            finish(new Error(ack.error && ack.error.length > 0 ? ack.error : '权限 RPC 调用失败'));
          }
        }
      }
    });

    socket.on('close', (error: BusinessError): void => {
      if (!done) {
        finish(new Error(error ? `权限 RPC 已断开：${error}` : '权限 RPC 已断开'));
      }
    });

    socket.on('error', (error: BusinessError): void => {
      finish(new Error(`权限 RPC 异常：${error}`));
    });

    try {
      socket.connect(buildSocketIoWebSocketUrl(serverUrl), {
        header: buildHeaders(),
      }).catch((error: BusinessError) => {
        finish(new Error(`权限 RPC 连接失败：${error}`));
      });
    } catch (error) {
      finish(new Error(`权限 RPC 连接异常：${error}`));
    }
  });
}

function buildSocketAuthPacket(token: string): string {
  const body: SocketAuthBody = {
    token,
    clientType: 'user-scoped',
    happyClient: HAPPY_CLIENT_ID,
  };
  return `40${JSON.stringify(body)}`;
}

function buildRpcCallPacket(ackId: number, body: RpcCallBody): string {
  return `42${ackId}${JSON.stringify(['rpc-call', body])}`;
}

function parseRpcAck(packet: string, ackId: number): RpcAckWire | null {
  const prefix = `43${ackId}`;
  if (!packet.startsWith(prefix)) {
    return null;
  }
  try {
    const parsed = JSON.parse(packet.substring(prefix.length)) as Object;
    if (!Array.isArray(parsed) || parsed.length === 0) {
      return null;
    }
    return parsed[0] as RpcAckWire;
  } catch {
    return null;
  }
}

function buildSocketIoWebSocketUrl(serverUrl: string): string {
  const normalized = normalizeServerUrl(serverUrl);
  if (normalized.startsWith('https://')) {
    return `wss://${normalized.substring('https://'.length)}${SOCKET_PATH}?EIO=4&transport=websocket`;
  }
  if (normalized.startsWith('http://')) {
    return `ws://${normalized.substring('http://'.length)}${SOCKET_PATH}?EIO=4&transport=websocket`;
  }
  throw new Error('服务器地址格式不正确');
}

function buildHeaders(): WebSocketHeaders {
  return {
    'X-Happy-Client': HAPPY_CLIENT_ID,
  };
}

function socketMessageToString(data: string | ArrayBuffer): string {
  if (typeof data === 'string') {
    return data;
  }
  return buffer.from(data).toString('utf8');
}

function normalizeServerUrl(url: string): string {
  let normalized = url.trim();
  while (normalized.length > 'https://'.length && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}
