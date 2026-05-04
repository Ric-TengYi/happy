export interface SocketIoRpcCall {
  method: string;
  params: string;
}

export interface SocketIoRpcAck {
  ok?: boolean;
  result?: string;
  error?: string;
}

export function buildSocketIoRpcCallPacket(ackId: number, call: SocketIoRpcCall): string {
  if (!Number.isInteger(ackId) || ackId <= 0) {
    throw new Error('Socket.IO ack id must be a positive integer');
  }
  if (call.method.trim().length === 0) {
    throw new Error('RPC method is empty');
  }
  return `42${ackId}${JSON.stringify(['rpc-call', {
    method: call.method,
    params: call.params,
  }])}`;
}

export function parseSocketIoRpcAckPacket(packet: string, expectedAckId: number): SocketIoRpcAck | null {
  const prefix = `43${expectedAckId}`;
  if (!packet.startsWith(prefix)) {
    return null;
  }
  const payloadText = packet.substring(prefix.length);
  let parsed: unknown;
  try {
    parsed = JSON.parse(payloadText);
  } catch {
    return null;
  }
  if (!Array.isArray(parsed) || parsed.length === 0 || !isRecord(parsed[0])) {
    return null;
  }
  return parsed[0] as SocketIoRpcAck;
}

export interface SessionPermissionRequestInput {
  id: string;
  approved: boolean;
  mode?: 'default' | 'acceptEdits' | 'bypassPermissions' | 'plan';
  allowTools?: string[];
  decision?: 'approved' | 'approved_for_session' | 'denied' | 'abort';
}

export function buildSessionPermissionRequest(input: SessionPermissionRequestInput): Record<string, unknown> {
  if (input.id.trim().length === 0) {
    throw new Error('Permission id is empty');
  }
  const request: Record<string, unknown> = {
    id: input.id,
    approved: input.approved,
  };
  if (input.mode) {
    request.mode = input.mode;
  }
  if (input.allowTools && input.allowTools.length > 0) {
    request.allowTools = input.allowTools;
  }
  if (input.decision) {
    request.decision = input.decision;
  }
  return request;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
