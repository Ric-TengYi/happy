import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { webSocket } from '@kit.NetworkKit';
import { Credentials } from './HappyAuth';

const HAPPY_CLIENT_ID: string = 'harmony/0.1.0';
const SOCKET_PATH: string = '/v1/updates/';
const RECONNECT_DELAY_MIN_MS: number = 1000;
const RECONNECT_DELAY_MAX_MS: number = 5000;

interface SocketAuthBody {
  token: string;
  clientType: string;
  happyClient: string;
}

interface WebSocketHeaders {
  'X-Happy-Client': string;
}

interface EphemeralWire {
  type?: string;
  id?: string;
  active?: boolean;
  activeAt?: number;
  thinking?: boolean;
}

interface RealtimePacket {
  type: string;
  payload?: Object;
}

export interface MachineActivityEvent {
  id: string;
  active: boolean;
  activeAt: number;
}

export interface SessionActivityEvent {
  id: string;
  active: boolean;
  activeAt: number;
  thinking: boolean;
}

export class HappyRealtimeSync {
  private socket: webSocket.WebSocket | null = null;
  private onStatus: ((status: string, message: string) => void) | null = null;
  private onConnected: (() => void) | null = null;
  private onDurableUpdate: (() => void) | null = null;
  private onMachineActivity: ((event: MachineActivityEvent) => void) | null = null;
  private onSessionActivity: ((event: SessionActivityEvent) => void) | null = null;
  private serverUrl: string = '';
  private token: string = '';
  private active: boolean = false;
  private reconnectTimerId: number = 0;
  private reconnectAttempt: number = 0;

  start(
    serverUrl: string,
    credentials: Credentials,
    onStatus: (status: string, message: string) => void,
    onConnected: () => void,
    onDurableUpdate: () => void,
    onMachineActivity: (event: MachineActivityEvent) => void,
    onSessionActivity: (event: SessionActivityEvent) => void,
  ): void {
    this.stop();
    this.serverUrl = normalizeServerUrl(serverUrl);
    this.token = credentials.token;
    this.onStatus = onStatus;
    this.onConnected = onConnected;
    this.onDurableUpdate = onDurableUpdate;
    this.onMachineActivity = onMachineActivity;
    this.onSessionActivity = onSessionActivity;
    this.active = true;
    this.reconnectAttempt = 0;
    this.connectNow();
  }

  stop(): void {
    this.active = false;
    this.clearReconnectTimer();
    this.closeSocket();
    this.onStatus = null;
    this.onConnected = null;
    this.onDurableUpdate = null;
    this.onMachineActivity = null;
    this.onSessionActivity = null;
    this.serverUrl = '';
    this.token = '';
    this.reconnectAttempt = 0;
  }

  private connectNow(): void {
    if (!this.active || this.token.length === 0 || this.serverUrl.length === 0) {
      return;
    }

    this.closeSocket();
    this.emitStatus('connecting', '实时同步连接中...');
    const socket = webSocket.createWebSocket();
    this.socket = socket;
    this.bindSocket(socket);

    try {
      socket.connect(buildSocketIoWebSocketUrl(this.serverUrl), {
        header: buildHeaders(),
      }).catch((error: BusinessError) => {
        if (this.socket !== socket || !this.active) {
          return;
        }
        console.error(`实时同步连接失败：${error}`);
        this.emitStatus('error', '实时同步连接失败，正在重试');
        this.scheduleReconnect();
      });
    } catch (error) {
      console.error(`实时同步连接异常：${error}`);
      this.emitStatus('error', '实时同步连接异常，正在重试');
      this.scheduleReconnect();
    }
  }

  private bindSocket(socket: webSocket.WebSocket): void {
    socket.on('open', (error: BusinessError): void => {
      if (this.socket !== socket || !this.active) {
        return;
      }
      if (error) {
        console.error(`实时同步打开失败：${error}`);
        this.emitStatus('error', '实时同步打开失败，正在重试');
        this.scheduleReconnect();
        return;
      }
      this.emitStatus('connecting', '实时同步握手中...');
    });

    socket.on('message', (error: BusinessError, data: string | ArrayBuffer): void => {
      if (this.socket !== socket || !this.active) {
        return;
      }
      if (error) {
        console.error(`实时同步消息接收失败：${error}`);
        this.emitStatus('error', '实时同步消息异常，正在重试');
        this.scheduleReconnect();
        return;
      }
      this.handleMessage(socketMessageToString(data));
    });

    socket.on('close', (error: BusinessError): void => {
      if (this.socket !== socket || !this.active) {
        return;
      }
      if (error) {
        console.error(`实时同步关闭异常：${error}`);
      }
      this.socket = null;
      this.emitStatus('disconnected', '实时同步已断开，正在重试');
      this.scheduleReconnect();
    });

    socket.on('error', (error: BusinessError): void => {
      if (this.socket !== socket || !this.active) {
        return;
      }
      console.error(`实时同步错误：${error}`);
      this.emitStatus('error', '实时同步异常，正在重试');
      this.scheduleReconnect();
    });
  }

  private handleMessage(packetText: string): void {
    const packet = parseSocketIoPacket(packetText);
    if (packet.type === 'engine-open') {
      this.sendSocketAuth();
    } else if (packet.type === 'engine-ping') {
      this.sendText('3');
    } else if (packet.type === 'socket-connected') {
      this.reconnectAttempt = 0;
      this.emitStatus('connected', '实时同步已连接');
      const onConnected = this.onConnected;
      if (onConnected) {
        onConnected();
      }
    } else if (packet.type === 'connect-error') {
      this.emitStatus('error', '实时同步鉴权失败，正在重试');
      this.scheduleReconnect();
    } else if (packet.type === 'update') {
      const onDurableUpdate = this.onDurableUpdate;
      if (onDurableUpdate) {
        onDurableUpdate();
      }
    } else if (packet.type === 'ephemeral' && packet.payload) {
      this.handleEphemeral(packet.payload);
    }
  }

  private handleEphemeral(payload: Object): void {
    const event = payload as EphemeralWire;
    if (!event.id || typeof event.active !== 'boolean' || typeof event.activeAt !== 'number') {
      return;
    }
    if (event.type === 'machine-activity') {
      const onMachineActivity = this.onMachineActivity;
      if (onMachineActivity) {
        onMachineActivity({
          id: event.id,
          active: event.active,
          activeAt: event.activeAt,
        });
      }
    } else if (event.type === 'activity') {
      const onSessionActivity = this.onSessionActivity;
      if (onSessionActivity) {
        onSessionActivity({
          id: event.id,
          active: event.active,
          activeAt: event.activeAt,
          thinking: event.thinking === true,
        });
      }
    }
  }

  private sendSocketAuth(): void {
    const body: SocketAuthBody = {
      token: this.token,
      clientType: 'user-scoped',
      happyClient: HAPPY_CLIENT_ID,
    };
    this.sendText(`40${JSON.stringify(body)}`);
  }

  private sendText(text: string): void {
    const socket = this.socket;
    if (!socket || !this.active) {
      return;
    }
    socket.send(text).catch((error: BusinessError) => {
      if (this.socket !== socket || !this.active) {
        return;
      }
      console.error(`实时同步发送失败：${error}`);
      this.emitStatus('error', '实时同步发送失败，正在重试');
      this.scheduleReconnect();
    });
  }

  private scheduleReconnect(): void {
    if (!this.active || this.reconnectTimerId !== 0) {
      return;
    }
    this.closeSocket();
    const delay = Math.min(RECONNECT_DELAY_MAX_MS, RECONNECT_DELAY_MIN_MS * Math.max(1, this.reconnectAttempt + 1));
    this.reconnectAttempt += 1;
    this.reconnectTimerId = setTimeout((): void => {
      this.reconnectTimerId = 0;
      this.connectNow();
    }, delay);
  }

  private closeSocket(): void {
    const socket = this.socket;
    if (!socket) {
      return;
    }
    this.socket = null;
    try {
      socket.off('open');
      socket.off('message');
      socket.off('close');
      socket.off('error');
      socket.close({ code: 1000, reason: 'client stop' }).catch((error: BusinessError) => {
        console.error(`实时同步关闭失败：${error}`);
      });
    } catch (error) {
      console.error(`实时同步关闭失败：${error}`);
    }
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimerId !== 0) {
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = 0;
    }
  }

  private emitStatus(status: string, message: string): void {
    const onStatus = this.onStatus;
    if (onStatus) {
      onStatus(status, message);
    }
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
  throw new Error('实时同步服务器地址格式不正确');
}

function buildHeaders(): WebSocketHeaders {
  return {
    'X-Happy-Client': HAPPY_CLIENT_ID,
  };
}

function parseSocketIoPacket(packet: string): RealtimePacket {
  if (packet.startsWith('0')) {
    return { type: 'engine-open' };
  }
  if (packet === '2') {
    return { type: 'engine-ping' };
  }
  if (packet === '1') {
    return { type: 'engine-close' };
  }
  if (packet.startsWith('40')) {
    return { type: 'socket-connected' };
  }
  if (packet.startsWith('44')) {
    return { type: 'connect-error' };
  }
  if (!packet.startsWith('42')) {
    return { type: 'ignored' };
  }

  const event = parseSocketEvent(packet.substring(2));
  if (!event) {
    return { type: 'ignored' };
  }
  if (event.name === 'update') {
    return { type: 'update', payload: event.payload };
  }
  if (event.name === 'ephemeral') {
    return { type: 'ephemeral', payload: event.payload };
  }
  return { type: 'ignored' };
}

function parseSocketEvent(text: string): SocketEvent | null {
  try {
    const parsed = JSON.parse(text) as Object;
    if (!Array.isArray(parsed)) {
      return null;
    }
    const event = parsed as Object[];
    if (event.length < 2 || typeof event[0] !== 'string') {
      return null;
    }
    return {
      name: event[0] as string,
      payload: event[1],
    };
  } catch {
    return null;
  }
}

interface SocketEvent {
  name: string;
  payload: Object;
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
