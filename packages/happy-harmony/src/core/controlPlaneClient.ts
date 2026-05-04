export interface ControlPlaneCredentials {
  token: string;
  secretBase64Url: string;
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
  cliAvailability?: {
    claude?: boolean;
    codex?: boolean;
    gemini?: boolean;
    openclaw?: boolean;
    detectedAt?: number;
  };
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
  summary?: {
    text: string;
    updatedAt: number;
  };
}

export interface ControlPlaneDecodeRequest {
  encrypted: string | null;
  dataEncryptionKey: string | null;
  kind: 'machine-metadata' | 'machine-daemon-state' | 'session-metadata' | 'session-agent-state';
}

export type ControlPlaneRecordDecoder = (
  request: ControlPlaneDecodeRequest,
  credentials: ControlPlaneCredentials,
) => Promise<unknown | null>;

export interface RawMachine {
  id: string;
  seq: number;
  createdAt: number;
  updatedAt: number;
  active: boolean;
  activeAt: number;
  metadata: string | null;
  metadataVersion: number;
  daemonState?: string | null;
  daemonStateVersion?: number;
  dataEncryptionKey?: string | null;
}

export interface RawSession {
  id: string;
  seq: number;
  createdAt: number;
  updatedAt: number;
  active: boolean;
  activeAt: number;
  metadata: string;
  metadataVersion: number;
  agentState: string | null;
  agentStateVersion: number;
  dataEncryptionKey: string | null;
  lastMessage?: unknown | null;
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
  daemonState: unknown | null;
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
  agentState: unknown | null;
  agentStateVersion: number;
  dataEncryptionKey: string | null;
}

export interface ControlPlaneSnapshot {
  machines: HappyMachine[];
  sessions: HappySession[];
}

export interface ControlPlaneClient {
  fetchSnapshot(credentials: ControlPlaneCredentials): Promise<ControlPlaneSnapshot>;
}

export interface ControlPlaneClientDependencies {
  getServerUrl(): string;
  getHappyClientId(): string;
  getJson<T>(url: string, headers: Record<string, string>): Promise<T>;
  decodeRecord: ControlPlaneRecordDecoder;
}

export function createControlPlaneClient(dependencies: ControlPlaneClientDependencies): ControlPlaneClient {
  return {
    async fetchSnapshot(credentials) {
      if (credentials.token.length === 0) {
        throw new Error('Auth token is empty');
      }

      const serverUrl = trimTrailingSlashes(dependencies.getServerUrl());
      const headers = authHeaders(credentials.token, dependencies.getHappyClientId());
      const machinesRaw = parseMachinesResponse(await dependencies.getJson<unknown>(`${serverUrl}/v1/machines`, headers));
      const sessionsRaw = parseSessionsResponse(await dependencies.getJson<unknown>(`${serverUrl}/v1/sessions`, headers));

      return {
        machines: await Promise.all(machinesRaw.map((machine) => decodeMachine(machine, credentials, dependencies.decodeRecord))),
        sessions: await Promise.all(sessionsRaw.map((session) => decodeSession(session, credentials, dependencies.decodeRecord))),
      };
    },
  };
}

export function formatMachineTitle(machine: { id: string; metadata: MachineMetadata | null }): string {
  const displayName = machine.metadata?.displayName?.trim();
  if (displayName) {
    return displayName;
  }
  const host = machine.metadata?.host?.trim();
  return host || machine.id;
}

export function formatMachineSubtitle(machine: { active: boolean; metadata: MachineMetadata | null }): string {
  const parts = new Array<string>(machine.active ? '在线' : '离线');
  const platform = machine.metadata?.platform?.trim();
  if (platform) {
    parts.push(platform);
  }
  const cliVersion = machine.metadata?.happyCliVersion?.trim();
  if (cliVersion) {
    parts.push(`CLI ${cliVersion}`);
  }
  return parts.join(' · ');
}

export function formatSessionTitle(session: { id: string; metadata: SessionMetadata | null }): string {
  const summary = session.metadata?.summary?.text?.trim();
  if (summary) {
    return summary;
  }
  const name = session.metadata?.name?.trim();
  if (name) {
    return name;
  }
  const path = session.metadata?.path?.trim();
  if (path) {
    const parts = path.split('/').filter(Boolean);
    return parts[parts.length - 1] ?? path;
  }
  return session.id;
}

async function decodeMachine(
  machine: RawMachine,
  credentials: ControlPlaneCredentials,
  decodeRecord: ControlPlaneRecordDecoder,
): Promise<HappyMachine> {
  return {
    id: machine.id,
    seq: machine.seq,
    createdAt: machine.createdAt,
    updatedAt: machine.updatedAt,
    active: machine.active,
    activeAt: machine.activeAt,
    metadata: asMachineMetadata(await decodeRecord({
      encrypted: machine.metadata,
      dataEncryptionKey: machine.dataEncryptionKey ?? null,
      kind: 'machine-metadata',
    }, credentials)),
    metadataVersion: machine.metadataVersion,
    daemonState: await decodeRecord({
      encrypted: machine.daemonState ?? null,
      dataEncryptionKey: machine.dataEncryptionKey ?? null,
      kind: 'machine-daemon-state',
    }, credentials),
    daemonStateVersion: machine.daemonStateVersion ?? 0,
    dataEncryptionKey: machine.dataEncryptionKey ?? null,
  };
}

async function decodeSession(
  session: RawSession,
  credentials: ControlPlaneCredentials,
  decodeRecord: ControlPlaneRecordDecoder,
): Promise<HappySession> {
  return {
    id: session.id,
    seq: session.seq,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    active: session.active,
    activeAt: session.activeAt,
    metadata: asSessionMetadata(await decodeRecord({
      encrypted: session.metadata,
      dataEncryptionKey: session.dataEncryptionKey,
      kind: 'session-metadata',
    }, credentials)),
    metadataVersion: session.metadataVersion,
    agentState: await decodeRecord({
      encrypted: session.agentState,
      dataEncryptionKey: session.dataEncryptionKey,
      kind: 'session-agent-state',
    }, credentials),
    agentStateVersion: session.agentStateVersion,
    dataEncryptionKey: session.dataEncryptionKey,
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

function parseMachinesResponse(value: unknown): RawMachine[] {
  if (!Array.isArray(value)) {
    throw new Error('Machine list response has an invalid shape');
  }
  return value as RawMachine[];
}

function parseSessionsResponse(value: unknown): RawSession[] {
  if (!isRecord(value) || !Array.isArray(value.sessions)) {
    throw new Error('Session list response has an invalid shape');
  }
  return value.sessions as RawSession[];
}

function asMachineMetadata(value: unknown | null): MachineMetadata | null {
  return isRecord(value) ? value as MachineMetadata : null;
}

function asSessionMetadata(value: unknown | null): SessionMetadata | null {
  return isRecord(value) ? value as SessionMetadata : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
