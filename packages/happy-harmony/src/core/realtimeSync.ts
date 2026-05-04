import type { HappyMachine, HappySession } from './controlPlaneClient';

export interface ApiUpdateContainer {
  id: string;
  seq: number;
  createdAt: number;
  body: ApiUpdateBody;
}

export type ApiUpdateBody =
  | { t: 'new-message'; sid: string; message?: unknown }
  | { t: 'new-session'; id: string }
  | { t: 'update-session'; id: string }
  | { t: 'delete-session'; sid: string }
  | { t: 'new-machine'; machineId: string }
  | { t: 'update-machine'; machineId: string }
  | { t: 'delete-machine'; machineId: string }
  | { t: string; [key: string]: unknown };

export interface ApiSessionActivityEvent {
  type: 'activity';
  id: string;
  active: boolean;
  activeAt: number;
  thinking: boolean;
}

export interface ApiMachineActivityEvent {
  type: 'machine-activity';
  id: string;
  active: boolean;
  activeAt: number;
}

export type ApiEphemeralEvent =
  | ApiSessionActivityEvent
  | ApiMachineActivityEvent
  | { type: string; [key: string]: unknown };

export type RealtimeSession = HappySession & {
  thinking?: boolean;
  thinkingAt?: number;
};

export interface RealtimeSnapshot {
  machines: HappyMachine[];
  sessions: RealtimeSession[];
}

export type ParsedSocketIoPacket =
  | { type: 'engine-open'; payload: unknown }
  | { type: 'engine-ping' }
  | { type: 'engine-pong' }
  | { type: 'engine-close' }
  | { type: 'socket-connected' }
  | { type: 'update'; update: ApiUpdateContainer }
  | { type: 'ephemeral'; event: ApiEphemeralEvent }
  | { type: 'ignored' };

export type RealtimeEvent =
  | Extract<ParsedSocketIoPacket, { type: 'socket-connected' | 'update' | 'ephemeral' }>;

export interface RealtimeApplyResult {
  snapshot: RealtimeSnapshot;
  needsRefresh: boolean;
  reason?: 'reconnect-catch-up' | 'durable-update' | 'unknown-machine' | 'unknown-session';
}

export function buildSocketIoWebSocketUrl(serverUrl: string): string {
  const url = new URL(trimTrailingSlashes(serverUrl));
  if (url.protocol === 'https:') {
    url.protocol = 'wss:';
  } else if (url.protocol === 'http:') {
    url.protocol = 'ws:';
  } else {
    throw new Error('Realtime server URL must use http or https');
  }
  url.pathname = appendPath(url.pathname, '/v1/updates/');
  url.search = 'EIO=4&transport=websocket';
  url.hash = '';
  return url.toString();
}

export function buildSocketIoAuthPacket(input: { token: string; happyClient: string }): string {
  return `40${JSON.stringify({
    token: input.token,
    clientType: 'user-scoped',
    happyClient: input.happyClient,
  })}`;
}

export function parseSocketIoPacket(packet: string): ParsedSocketIoPacket {
  if (packet.startsWith('0')) {
    return { type: 'engine-open', payload: parseJsonPayload(packet.slice(1)) };
  }
  if (packet === '2') {
    return { type: 'engine-ping' };
  }
  if (packet === '3') {
    return { type: 'engine-pong' };
  }
  if (packet === '1') {
    return { type: 'engine-close' };
  }
  if (packet.startsWith('40')) {
    return { type: 'socket-connected' };
  }
  if (!packet.startsWith('42')) {
    return { type: 'ignored' };
  }

  const payload = parseJsonPayload(packet.slice(2));
  if (!Array.isArray(payload) || typeof payload[0] !== 'string') {
    return { type: 'ignored' };
  }
  if (payload[0] === 'update' && isRecord(payload[1])) {
    return { type: 'update', update: payload[1] as unknown as ApiUpdateContainer };
  }
  if (payload[0] === 'ephemeral' && isRecord(payload[1])) {
    return { type: 'ephemeral', event: payload[1] as ApiEphemeralEvent };
  }
  return { type: 'ignored' };
}

export function applyRealtimeEvent(snapshot: RealtimeSnapshot, event: RealtimeEvent): RealtimeApplyResult {
  if (event.type === 'socket-connected') {
    return { snapshot, needsRefresh: true, reason: 'reconnect-catch-up' };
  }
  if (event.type === 'update') {
    return { snapshot, needsRefresh: true, reason: 'durable-update' };
  }
  if (isMachineActivityEvent(event.event)) {
    return patchMachineActivity(snapshot, event.event);
  }
  if (isSessionActivityEvent(event.event)) {
    return patchSessionActivity(snapshot, event.event);
  }
  return { snapshot, needsRefresh: false };
}

function patchMachineActivity(
  snapshot: RealtimeSnapshot,
  event: ApiMachineActivityEvent,
): RealtimeApplyResult {
  let found = false;
  const machines = snapshot.machines.map((machine) => {
    if (machine.id !== event.id) {
      return machine;
    }
    found = true;
    return {
      ...machine,
      active: event.active,
      activeAt: event.activeAt,
    };
  });

  if (!found) {
    return { snapshot, needsRefresh: true, reason: 'unknown-machine' };
  }
  return {
    snapshot: { machines, sessions: snapshot.sessions },
    needsRefresh: false,
  };
}

function patchSessionActivity(
  snapshot: RealtimeSnapshot,
  event: ApiSessionActivityEvent,
): RealtimeApplyResult {
  let found = false;
  const sessions = snapshot.sessions.map((session) => {
    if (session.id !== event.id) {
      return session;
    }
    found = true;
    return {
      ...session,
      active: event.active,
      activeAt: event.activeAt,
      thinking: event.thinking,
      thinkingAt: event.activeAt,
    };
  });

  if (!found) {
    return { snapshot, needsRefresh: true, reason: 'unknown-session' };
  }
  return {
    snapshot: { machines: snapshot.machines, sessions },
    needsRefresh: false,
  };
}

function appendPath(basePath: string, socketPath: string): string {
  const cleanBase = basePath === '/' ? '' : trimTrailingSlashes(basePath);
  return `${cleanBase}${socketPath}`;
}

function trimTrailingSlashes(value: string): string {
  let trimmed = value.trim();
  while (trimmed.length > 'https://'.length && trimmed.endsWith('/')) {
    trimmed = trimmed.slice(0, -1);
  }
  return trimmed;
}

function parseJsonPayload(text: string): unknown {
  if (text.length === 0) {
    return null;
  }
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isMachineActivityEvent(event: ApiEphemeralEvent): event is ApiMachineActivityEvent {
  return event.type === 'machine-activity'
    && typeof event.id === 'string'
    && typeof event.active === 'boolean'
    && typeof event.activeAt === 'number';
}

function isSessionActivityEvent(event: ApiEphemeralEvent): event is ApiSessionActivityEvent {
  return event.type === 'activity'
    && typeof event.id === 'string'
    && typeof event.active === 'boolean'
    && typeof event.activeAt === 'number'
    && typeof event.thinking === 'boolean';
}
