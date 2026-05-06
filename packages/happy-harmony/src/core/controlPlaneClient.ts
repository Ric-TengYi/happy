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

export interface NewSessionAgentAvailability {
  claude?: boolean;
  codex?: boolean;
  gemini?: boolean;
  openclaw?: boolean;
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
  codexThreadId?: string;
  lifecycleState?: string;
  lifecycleStateSince?: number;
  archivedBy?: string;
  archiveReason?: string;
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

export interface MachineDetailRow {
  group: string;
  label: string;
  value: string;
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
  const name = session.metadata?.name?.trim();
  if (name) {
    return name;
  }
  const summary = session.metadata?.summary?.text?.trim();
  if (summary) {
    return summary;
  }
  const path = session.metadata?.path?.trim();
  if (path) {
    const parts = path.split('/').filter(Boolean);
    return parts[parts.length - 1] ?? path;
  }
  return session.id;
}

export function formatSessionPath(path: string, homeDir = ''): string {
  let displayPath = path.trim();
  if (!displayPath) {
    return '';
  }

  const normalizedHome = trimPathTrailingSlash(homeDir.trim());
  if (normalizedHome && (displayPath === normalizedHome || displayPath.startsWith(`${normalizedHome}/`))) {
    displayPath = displayPath === normalizedHome ? '~' : `~/${displayPath.slice(normalizedHome.length + 1)}`;
  } else {
    displayPath = abbreviateDetectedHomePath(displayPath);
  }

  return shortenPathTail(displayPath);
}

export function buildMachineRenameMetadata(metadata: MachineMetadata | null, displayName: string): MachineMetadata {
  return {
    ...(metadata ?? {}),
    displayName: normalizeRenameValue(displayName),
  };
}

export function buildSessionRenameMetadata(metadata: SessionMetadata | null, name: string): SessionMetadata {
  const renameValue = normalizeRenameValue(name);
  return {
    ...(metadata ?? {}),
    name: renameValue,
  };
}

export function buildSessionArchiveMetadata(metadata: SessionMetadata | null, now: number = Date.now()): SessionMetadata {
  return {
    ...(metadata ?? {}),
    lifecycleState: 'archiveRequested',
    lifecycleStateSince: now,
    archivedBy: 'harmony',
    archiveReason: 'User archived from Harmony',
  };
}

export function isSessionArchived(session: { active?: boolean; metadata: SessionMetadata | null }): boolean {
  const lifecycleState = session.metadata?.lifecycleState?.trim();
  return lifecycleState === 'archiveRequested' || lifecycleState === 'archived';
}

export function filterVisibleSessions<T extends { metadata: SessionMetadata | null }>(sessions: T[]): T[] {
  return sessions.filter((session) => !isSessionArchived(session));
}

export function mergeMachineSnapshotWithLocalMetadata(
  previousMachines: HappyMachine[],
  nextMachines: HappyMachine[],
): HappyMachine[] {
  return nextMachines.map((machine) => {
    const previous = previousMachines.find((item) => item.id === machine.id);
    if (!previous || previous.metadataVersion <= machine.metadataVersion) {
      return machine;
    }
    return {
      ...machine,
      metadata: previous.metadata,
      metadataVersion: previous.metadataVersion,
    };
  });
}

export function mergeSessionSnapshotWithLocalMetadata(
  previousSessions: HappySession[],
  nextSessions: HappySession[],
): HappySession[] {
  return nextSessions.map((session) => {
    const previous = previousSessions.find((item) => item.id === session.id);
    if (!previous || previous.metadataVersion <= session.metadataVersion) {
      return session;
    }
    return {
      ...session,
      metadata: previous.metadata,
      metadataVersion: previous.metadataVersion,
    };
  });
}

export function formatMachineRowKey(machine: Pick<HappyMachine, 'id' | 'active' | 'activeAt' | 'metadataVersion' | 'daemonStateVersion'>): string {
  return [
    machine.id,
    machine.active ? '1' : '0',
    machine.activeAt,
    machine.metadataVersion,
    machine.daemonStateVersion,
  ].join(':');
}

export function formatSessionRowKey(
  session: {
    id: string;
    active: boolean;
    activeAt: number;
    thinking?: boolean;
    thinkingAt?: number;
    metadataVersion: number;
    agentStateVersion: number;
  },
): string {
  return [
    session.id,
    session.active ? '1' : '0',
    session.activeAt,
    session.thinking ? '1' : '0',
    session.thinkingAt ?? 0,
    session.metadataVersion,
    session.agentStateVersion,
  ].join(':');
}

export function formatMachineDaemonStatus(machine: { active: boolean; metadata: MachineMetadata | null }): string {
  if (machine.metadata?.daemonLastKnownStatus?.trim() === 'shutting-down') {
    return '已停止';
  }
  return machine.active ? '运行中' : '已停止';
}

export function listRecentMachineSessionPaths(
  sessions: Array<{ updatedAt: number; metadata: Pick<SessionMetadata, 'machineId' | 'path'> | null }>,
  machineId: string,
  limit: number = 5,
): string[] {
  const paths: string[] = [];
  const seen = new Set<string>();
  const sorted = [...sessions].sort((a, b) => b.updatedAt - a.updatedAt);
  for (const session of sorted) {
    if (session.metadata?.machineId !== machineId) {
      continue;
    }
    const path = session.metadata.path?.trim();
    if (!path || seen.has(path)) {
      continue;
    }
    paths.push(path);
    seen.add(path);
    if (limit > 0 && paths.length >= limit) {
      break;
    }
  }
  return paths;
}

export function resolveMachineSpawnPath(path: string, homeDir: string | undefined): string {
  const trimmed = path.trim();
  const normalizedHome = homeDir?.trim();
  if (!normalizedHome || !trimmed.startsWith('~')) {
    return trimmed;
  }
  const home = trimPathTrailingSlash(normalizedHome);
  if (trimmed === '~') {
    return home;
  }
  if (trimmed.startsWith('~/')) {
    return `${home}/${trimmed.slice(2)}`;
  }
  return trimmed;
}

export function resolveCodexThreadListCwd(path: string, homeDir: string | undefined): string | null {
  const resolved = resolveMachineSpawnPath(path, homeDir).trim();
  return resolved.length > 0 ? resolved : null;
}

export function choosePreferredNewSessionAgent(options: Array<{ key: string }>): string {
  for (const option of options) {
    if (option.key === 'codex') {
      return 'codex';
    }
  }
  return options.length > 0 ? options[0].key : '';
}

export function filterNewSessionAgentOptionsForAvailability<T extends { key: string }>(
  options: T[],
  availability: NewSessionAgentAvailability | null | undefined,
): T[] {
  if (!availability) {
    return options;
  }
  return options.filter((option) => isNewSessionAgentAvailable(availability, option.key));
}

function isNewSessionAgentAvailable(availability: NewSessionAgentAvailability, agent: string): boolean {
  if (agent === 'claude') {
    return availability.claude === true;
  }
  if (agent === 'codex') {
    return availability.codex === true;
  }
  if (agent === 'openclaw') {
    return availability.openclaw === true;
  }
  if (agent === 'gemini') {
    return availability.gemini === true;
  }
  return false;
}

export function buildMachineDetailRows(machine: HappyMachine): MachineDetailRow[] {
  const rows: MachineDetailRow[] = [];
  const metadata = machine.metadata;
  const daemonState = asRecord(machine.daemonState);

  pushRow(rows, '守护进程', '状态', formatMachineDaemonStatus(machine));
  pushOptionalRow(rows, '守护进程', '最后 PID', readRecordText(daemonState, 'pid'));
  pushOptionalRow(rows, '守护进程', '最后 HTTP 端口', readRecordText(daemonState, 'httpPort'));
  pushOptionalRow(rows, '守护进程', '启动时间', formatOptionalTimestamp(readRecordNumber(daemonState, 'startTime')));
  pushOptionalRow(rows, '守护进程', 'CLI 版本', readRecordText(daemonState, 'startedWithCliVersion'));
  pushRow(rows, '守护进程', '守护进程状态版本', String(machine.daemonStateVersion));

  if (metadata?.cliAvailability) {
    pushRow(rows, 'CLI 可用性', 'Claude', metadata.cliAvailability.claude ? '已安装' : '未检测到');
    pushRow(rows, 'CLI 可用性', 'Codex', metadata.cliAvailability.codex ? '已安装' : '未检测到');
    pushRow(rows, 'CLI 可用性', 'Gemini', metadata.cliAvailability.gemini ? '已安装' : '未检测到');
    pushRow(rows, 'CLI 可用性', 'OpenClaw', metadata.cliAvailability.openclaw ? '已安装' : '未检测到');
    pushOptionalRow(rows, 'CLI 可用性', '最后检测', formatOptionalTimestamp(metadata.cliAvailability.detectedAt));
  }

  pushOptionalRow(rows, '终端', '主机', metadata?.host);
  pushRow(rows, '终端', '终端 ID', machine.id);
  pushOptionalRow(rows, '终端', '用户名', metadata?.username);
  pushOptionalRow(rows, '终端', '主目录', metadata?.homeDir);
  pushOptionalRow(rows, '终端', 'Happy 目录', metadata?.happyHomeDir);
  pushOptionalRow(rows, '终端', '平台', metadata?.platform);
  pushOptionalRow(rows, '终端', '架构', metadata?.arch);
  pushOptionalRow(rows, '终端', 'Happy CLI', metadata?.happyCliVersion);
  pushOptionalRow(rows, '终端', '最后在线', formatOptionalTimestamp(machine.activeAt));
  pushRow(rows, '终端', '元数据版本', String(machine.metadataVersion));
  pushOptionalRow(rows, '终端', '创建时间', formatOptionalTimestamp(machine.createdAt));
  pushOptionalRow(rows, '终端', '更新时间', formatOptionalTimestamp(machine.updatedAt));

  return rows;
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

function normalizeRenameValue(value: string): string | undefined {
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function pushRow(rows: MachineDetailRow[], group: string, label: string, value: string): void {
  rows.push({ group, label, value });
}

function pushOptionalRow(rows: MachineDetailRow[], group: string, label: string, value: string | undefined): void {
  const normalized = value?.trim();
  if (normalized) {
    pushRow(rows, group, label, normalized);
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function readRecordText(record: Record<string, unknown> | null, key: string): string | undefined {
  if (!record) {
    return undefined;
  }
  const value = record[key];
  if (typeof value === 'string') {
    return value;
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  return undefined;
}

function readRecordNumber(record: Record<string, unknown> | null, key: string): number | undefined {
  if (!record) {
    return undefined;
  }
  const value = record[key];
  return typeof value === 'number' ? value : undefined;
}

function formatOptionalTimestamp(timestamp: number | undefined): string | undefined {
  if (!timestamp || timestamp <= 0) {
    return undefined;
  }
  return new Date(timestamp).toLocaleString();
}

function trimTrailingSlashes(url: string): string {
  let trimmed = url.trim();
  while (trimmed.length > 'https://'.length && trimmed.endsWith('/')) {
    trimmed = trimmed.slice(0, -1);
  }
  return trimmed;
}

function trimPathTrailingSlash(value: string): string {
  let result = value;
  while (result.length > 1 && result.endsWith('/')) {
    result = result.slice(0, result.length - 1);
  }
  return result;
}

function abbreviateDetectedHomePath(path: string): string {
  const userHome = abbreviateHomePrefix(path, '/Users/');
  if (userHome !== path) {
    return userHome;
  }
  return abbreviateHomePrefix(path, '/home/');
}

function abbreviateHomePrefix(path: string, root: string): string {
  if (!path.startsWith(root)) {
    return path;
  }
  const rest = path.slice(root.length);
  const slashIndex = rest.indexOf('/');
  if (slashIndex < 0) {
    return rest.length > 0 ? '~' : path;
  }
  const username = rest.slice(0, slashIndex);
  if (!username) {
    return path;
  }
  const prefix = `${root}${username}`;
  return path === prefix ? '~' : `~/${path.slice(prefix.length + 1)}`;
}

function shortenPathTail(path: string): string {
  const prefix = path.startsWith('~/') ? '~/' : path.startsWith('/') ? '/' : '';
  const body = prefix ? path.slice(prefix.length) : path;
  const parts = body.split('/').filter(Boolean);
  if (parts.length <= 3) {
    return path;
  }

  const tail = `${parts[parts.length - 2]}/${parts[parts.length - 1]}`;
  if (prefix === '~/') {
    return `~/.../${tail}`;
  }
  if (prefix === '/') {
    return `/.../${tail}`;
  }
  return `.../${tail}`;
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
