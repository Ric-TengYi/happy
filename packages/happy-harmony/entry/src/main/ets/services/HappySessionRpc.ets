import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { http, webSocket } from '@kit.NetworkKit';
import { Credentials, loadCredentials } from './HappyAuth';
import { HappyMachine, HappySession, MachineMetadata, SessionMetadata, buildSessionArchiveMetadata } from './HappySync';
import { HappyPermission, decryptRawPayload, encryptRawPayload, encryptSessionRawPayload } from './HappyMessages';

const HAPPY_CLIENT_ID: string = 'harmony/0.1.0';
const SOCKET_PATH: string = '/v1/updates/';
const RPC_ACK_ID: number = 1;
const RPC_TIMEOUT_MS: number = 12000;
const MACHINE_SPAWN_RPC_TIMEOUT_MS: number = 30000;
const MACHINE_CODEX_SYNC_RPC_TIMEOUT_MS: number = 60000;

interface WebSocketHeaders {
  'X-Happy-Client': string;
}

interface HttpHeaders {
  'Authorization': string;
  'Content-Type': string;
  'X-Happy-Client': string;
}

interface TextResponse {
  ok: boolean;
  statusCode: number;
  text: string;
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

interface SocketAckWire {
  ok?: boolean;
  result?: string;
  error?: string;
  version?: number;
  metadata?: string | null;
  message?: string;
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

interface SessionKillRequest {
  reason?: string;
}

export type PermissionAction = 'allow' | 'allowForSession' | 'allowAllEdits' | 'allowEverything' | 'deny';

export interface SpawnMachineSessionOptions {
  directory: string;
  approvedNewDirectoryCreation?: boolean;
  token?: string;
  agent?: string;
}

interface SpawnMachineSessionRequest {
  type: string;
  directory: string;
  approvedNewDirectoryCreation?: boolean;
  token?: string;
  agent?: string;
}

interface CodexThreadListRequest {
  cursor?: string | null;
  limit?: number;
  cwd?: string | null;
  searchTerm?: string | null;
  archived?: boolean;
}

interface DirectoryListRequest {
  path?: string | null;
  showHidden?: boolean;
  limit?: number;
}

interface AttachCodexThreadRequest {
  threadId: string;
  cwd?: string | null;
  threadName?: string | null;
}

interface CodexThreadSyncRequest {
  happySessionId: string;
  threadId?: string | null;
}

interface StopMachineDaemonRequest {
  request?: string;
}

interface MachineMetadataUpdateBody {
  machineId: string;
  metadata: string;
  expectedVersion: number;
}

interface SessionMetadataUpdateBody {
  sid: string;
  metadata: string;
  expectedVersion: number;
}

export interface SpawnMachineSessionResult {
  type: string;
  sessionId?: string;
  directory?: string;
  errorMessage?: string;
}

export interface CodexThreadSummary {
  id: string;
  name: string;
  preview: string;
  cwd: string;
  path: string;
  source: string;
  modelProvider: string;
  cliVersion: string;
  createdAt: number;
  updatedAt: number;
}

export interface CodexThreadListResult {
  threads: CodexThreadSummary[];
  nextCursor: string;
  backwardsCursor: string;
}

export interface CodexThreadSyncResult {
  type: string;
  threadId: string;
  imported: number;
  errorMessage?: string;
}

export interface DirectoryEntrySummary {
  name: string;
  path: string;
  type: string;
  hidden: boolean;
}

export interface DirectoryListResult {
  path: string;
  parentPath: string | null;
  entries: DirectoryEntrySummary[];
  truncated: boolean;
}

export interface StopMachineDaemonResult {
  message: string;
}

export interface MachineDeleteResult {
  message: string;
}

export interface MachineRenameResult {
  version: number;
  metadata: MachineMetadata;
}

export interface SessionRenameResult {
  version: number;
  metadata: SessionMetadata;
}

export interface SessionArchiveResult {
  version: number;
  metadata: SessionMetadata;
  message?: string;
}

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
  await sendRpc(serverUrl, credentials, `${session.id}:permission`, encryptedParams, '权限 RPC');
}

export async function spawnMachineSession(
  context: common.UIAbilityContext,
  serverUrl: string,
  machine: HappyMachine,
  options: SpawnMachineSessionOptions,
): Promise<SpawnMachineSessionResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (machine.id.length === 0) {
    throw new Error('终端 ID 为空');
  }

  const request: SpawnMachineSessionRequest = {
    type: 'spawn-in-directory',
    directory: options.directory,
    approvedNewDirectoryCreation: options.approvedNewDirectoryCreation === true,
    token: options.token,
    agent: options.agent,
  };
  const encryptedParams = encryptRawPayload(request, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  const ack = await sendRpc(
    serverUrl,
    credentials,
    `${machine.id}:spawn-happy-session`,
    encryptedParams,
    '终端 RPC',
    MACHINE_SPAWN_RPC_TIMEOUT_MS,
  );
  if (!ack.result || ack.result.length === 0) {
    return {
      type: 'error',
      errorMessage: '终端未返回创建结果',
    };
  }
  const decrypted = decryptRawPayload(ack.result, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  return normalizeSpawnMachineSessionResult(decrypted);
}

export async function listCodexThreads(
  context: common.UIAbilityContext,
  serverUrl: string,
  machine: HappyMachine,
  options?: CodexThreadListRequest,
): Promise<CodexThreadListResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (machine.id.length === 0) {
    throw new Error('终端 ID 为空');
  }

  const request: CodexThreadListRequest = {
    cursor: options?.cursor ?? null,
    limit: options?.limit ?? 20,
    cwd: options?.cwd ?? null,
    searchTerm: options?.searchTerm ?? null,
    archived: options?.archived === true,
  };
  const encryptedParams = encryptRawPayload(request, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  const ack = await sendRpc(
    serverUrl,
    credentials,
    `${machine.id}:codex-thread-list`,
    encryptedParams,
    'Codex 会话列表',
    MACHINE_SPAWN_RPC_TIMEOUT_MS,
  );
  if (!ack.result || ack.result.length === 0) {
    return { threads: [], nextCursor: '', backwardsCursor: '' };
  }
  const decrypted = decryptRawPayload(ack.result, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  return normalizeCodexThreadListResult(decrypted);
}

export async function attachCodexThread(
  context: common.UIAbilityContext,
  serverUrl: string,
  machine: HappyMachine,
  thread: CodexThreadSummary,
): Promise<SpawnMachineSessionResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (machine.id.length === 0) {
    throw new Error('终端 ID 为空');
  }
  if (thread.id.length === 0) {
    throw new Error('Codex 会话 ID 为空');
  }

  const request: AttachCodexThreadRequest = {
    threadId: thread.id,
    cwd: thread.cwd.length > 0 ? thread.cwd : null,
    threadName: getCodexThreadAttachName(thread),
  };
  const encryptedParams = encryptRawPayload(request, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  const ack = await sendRpc(
    serverUrl,
    credentials,
    `${machine.id}:codex-thread-attach`,
    encryptedParams,
    '接入 Codex 会话',
    MACHINE_SPAWN_RPC_TIMEOUT_MS,
  );
  if (!ack.result || ack.result.length === 0) {
    return {
      type: 'error',
      errorMessage: '终端未返回接入结果',
    };
  }
  const decrypted = decryptRawPayload(ack.result, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  return normalizeSpawnMachineSessionResult(decrypted);
}

export async function syncCodexThread(
  context: common.UIAbilityContext,
  serverUrl: string,
  machine: HappyMachine,
  session: HappySession,
  threadId: string,
): Promise<CodexThreadSyncResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (machine.id.length === 0) {
    throw new Error('终端 ID 为空');
  }
  if (session.id.length === 0) {
    throw new Error('会话 ID 为空');
  }

  const request: CodexThreadSyncRequest = {
    happySessionId: session.id,
    threadId: threadId.length > 0 ? threadId : null,
  };
  const encryptedParams = encryptRawPayload(request, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  const ack = await sendRpc(
    serverUrl,
    credentials,
    `${machine.id}:codex-thread-sync`,
    encryptedParams,
    '同步 Codex 历史',
    MACHINE_CODEX_SYNC_RPC_TIMEOUT_MS,
  );
  if (!ack.result || ack.result.length === 0) {
    return {
      type: 'success',
      threadId,
      imported: 0,
    };
  }
  const decrypted = decryptRawPayload(ack.result, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  return normalizeCodexThreadSyncResult(decrypted);
}

export async function listMachineDirectories(
  context: common.UIAbilityContext,
  serverUrl: string,
  machine: HappyMachine,
  options?: DirectoryListRequest,
): Promise<DirectoryListResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (machine.id.length === 0) {
    throw new Error('终端 ID 为空');
  }

  const request: DirectoryListRequest = {
    path: options?.path ?? null,
    showHidden: options?.showHidden === true,
    limit: options?.limit ?? 100,
  };
  const encryptedParams = encryptRawPayload(request, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  const ack = await sendRpc(
    serverUrl,
    credentials,
    `${machine.id}:directory-list`,
    encryptedParams,
    '目录列表',
    MACHINE_SPAWN_RPC_TIMEOUT_MS,
  );
  if (!ack.result || ack.result.length === 0) {
    return { path: request.path ?? '', parentPath: null, entries: [], truncated: false };
  }
  const decrypted = decryptRawPayload(ack.result, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  return normalizeDirectoryListResult(decrypted);
}

export async function stopMachineDaemon(
  context: common.UIAbilityContext,
  serverUrl: string,
  machine: HappyMachine,
): Promise<StopMachineDaemonResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (machine.id.length === 0) {
    throw new Error('终端 ID 为空');
  }

  const request: StopMachineDaemonRequest = {};
  const encryptedParams = encryptRawPayload(request, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  const ack = await sendRpc(serverUrl, credentials, `${machine.id}:stop-daemon`, encryptedParams, '停止守护进程');
  if (!ack.result || ack.result.length === 0) {
    return { message: '停止守护进程请求已发送' };
  }
  const decrypted = decryptRawPayload(ack.result, machine.dataEncryptionKey, credentials, '终端密钥不可用');
  return normalizeStopMachineDaemonResult(decrypted);
}

export async function deleteMachine(
  context: common.UIAbilityContext,
  serverUrl: string,
  machine: HappyMachine,
): Promise<MachineDeleteResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (machine.id.length === 0) {
    throw new Error('终端 ID 为空');
  }

  const headers: HttpHeaders = {
    'Authorization': `Bearer ${credentials.token}`,
    'Content-Type': 'application/json',
    'X-Happy-Client': HAPPY_CLIENT_ID,
  };
  const response = await requestText(
    `${normalizeServerUrl(serverUrl)}/v1/machines/${encodeURIComponent(machine.id)}`,
    http.RequestMethod.DELETE,
    headers,
  );
  if (!response.ok) {
    throw new Error(parseHttpErrorMessage(response.text, `删除设备失败：${response.statusCode}`));
  }
  return { message: '设备已删除' };
}

export async function renameMachine(
  context: common.UIAbilityContext,
  serverUrl: string,
  machine: HappyMachine,
  displayName: string,
): Promise<MachineRenameResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (machine.id.length === 0) {
    throw new Error('终端 ID 为空');
  }

  let currentVersion = machine.metadataVersion;
  let currentMetadata = buildMachineRenameMetadata(machine.metadata, displayName);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const encryptedMetadata = encryptRawPayload(currentMetadata, machine.dataEncryptionKey, credentials, '终端密钥不可用');
    const body: MachineMetadataUpdateBody = {
      machineId: machine.id,
      metadata: encryptedMetadata,
      expectedVersion: currentVersion,
    };
    const ack = await sendSocketEventWithAck(serverUrl, credentials, 'machine-update-metadata', body, '终端重命名');

    if (ack.result === 'success') {
      const encryptedResult = getAckMetadata(ack, encryptedMetadata, '终端重命名');
      return {
        version: getAckVersion(ack, '终端重命名'),
        metadata: decryptRawPayload(encryptedResult, machine.dataEncryptionKey, credentials, '终端密钥不可用') as MachineMetadata,
      };
    }
    if (ack.result === 'version-mismatch') {
      currentVersion = getAckVersion(ack, '终端重命名');
      const latestEncrypted = getAckMetadata(ack, '', '终端重命名');
      const latestMetadata = decryptRawPayload(latestEncrypted, machine.dataEncryptionKey, credentials, '终端密钥不可用') as MachineMetadata;
      currentMetadata = buildMachineRenameMetadata(latestMetadata, displayName);
    } else {
      throw new Error(getAckErrorMessage(ack, '终端重命名失败'));
    }
  }
  throw new Error('终端名称冲突，请同步后重试');
}

export async function renameSession(
  context: common.UIAbilityContext,
  serverUrl: string,
  session: HappySession,
  name: string,
): Promise<SessionRenameResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (session.id.length === 0) {
    throw new Error('会话 ID 为空');
  }

  let currentVersion = session.metadataVersion;
  let currentMetadata = buildSessionRenameMetadata(session.metadata, name);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const encryptedMetadata = encryptSessionRawPayload(currentMetadata, session, credentials);
    const body: SessionMetadataUpdateBody = {
      sid: session.id,
      metadata: encryptedMetadata,
      expectedVersion: currentVersion,
    };
    const ack = await sendSocketEventWithAck(serverUrl, credentials, 'update-metadata', body, '会话重命名');

    if (ack.result === 'success') {
      const encryptedResult = getAckMetadata(ack, encryptedMetadata, '会话重命名');
      return {
        version: getAckVersion(ack, '会话重命名'),
        metadata: decryptRawPayload(encryptedResult, session.dataEncryptionKey, credentials, '会话密钥不可用') as SessionMetadata,
      };
    }
    if (ack.result === 'version-mismatch') {
      currentVersion = getAckVersion(ack, '会话重命名');
      const latestEncrypted = getAckMetadata(ack, '', '会话重命名');
      const latestMetadata = decryptRawPayload(latestEncrypted, session.dataEncryptionKey, credentials, '会话密钥不可用') as SessionMetadata;
      currentMetadata = buildSessionRenameMetadata(latestMetadata, name);
    } else {
      throw new Error(getAckErrorMessage(ack, '会话重命名失败'));
    }
  }
  throw new Error('会话名称冲突，请同步后重试');
}

export async function archiveSession(
  context: common.UIAbilityContext,
  serverUrl: string,
  session: HappySession,
): Promise<SessionArchiveResult> {
  const credentials = await loadCredentials(context);
  if (!credentials) {
    throw new Error('请先登录账号');
  }
  if (credentials.token.length === 0) {
    throw new Error('登录 token 为空');
  }
  if (session.id.length === 0) {
    throw new Error('会话 ID 为空');
  }

  const result = await updateSessionArchiveMetadata(serverUrl, credentials, session);
  const warning = await stopSessionForArchive(serverUrl, credentials, session);
  if (warning.length > 0) {
    return {
      version: result.version,
      metadata: result.metadata,
      message: warning,
    };
  }
  return result;
}

async function updateSessionArchiveMetadata(
  serverUrl: string,
  credentials: Credentials,
  session: HappySession,
): Promise<SessionArchiveResult> {
  let currentVersion = session.metadataVersion;
  let currentMetadata = buildSessionArchiveMetadata(session.metadata);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const encryptedMetadata = encryptSessionRawPayload(currentMetadata, session, credentials);
    const body: SessionMetadataUpdateBody = {
      sid: session.id,
      metadata: encryptedMetadata,
      expectedVersion: currentVersion,
    };
    const ack = await sendSocketEventWithAck(serverUrl, credentials, 'update-metadata', body, '会话归档');

    if (ack.result === 'success') {
      const encryptedResult = getAckMetadata(ack, encryptedMetadata, '会话归档');
      return {
        version: getAckVersion(ack, '会话归档'),
        metadata: decryptRawPayload(encryptedResult, session.dataEncryptionKey, credentials, '会话密钥不可用') as SessionMetadata,
      };
    }
    if (ack.result === 'version-mismatch') {
      currentVersion = getAckVersion(ack, '会话归档');
      const latestEncrypted = getAckMetadata(ack, '', '会话归档');
      const latestMetadata = decryptRawPayload(latestEncrypted, session.dataEncryptionKey, credentials, '会话密钥不可用') as SessionMetadata;
      currentMetadata = buildSessionArchiveMetadata(latestMetadata);
    } else {
      throw new Error(getAckErrorMessage(ack, '会话归档失败'));
    }
  }
  throw new Error('会话归档冲突，请同步后重试');
}

async function stopSessionForArchive(
  serverUrl: string,
  credentials: Credentials,
  session: HappySession,
): Promise<string> {
  try {
    const request: SessionKillRequest = {};
    const encryptedParams = encryptSessionRawPayload(request, session, credentials);
    await sendRpc(serverUrl, credentials, `${session.id}:killSession`, encryptedParams, '会话归档');
    return '';
  } catch (killError) {
    try {
      await forceArchiveSessionOnServer(serverUrl, credentials, session.id);
      return '';
    } catch (archiveError) {
      const killMessage = stringifyError(killError);
      const archiveMessage = stringifyError(archiveError);
      return `归档标记已保存，但停止终端失败：${archiveMessage.length > 0 ? archiveMessage : killMessage}`;
    }
  }
}

async function forceArchiveSessionOnServer(
  serverUrl: string,
  credentials: Credentials,
  sessionId: string,
): Promise<void> {
  const headers: HttpHeaders = {
    'Authorization': `Bearer ${credentials.token}`,
    'Content-Type': 'application/json',
    'X-Happy-Client': HAPPY_CLIENT_ID,
  };
  const response = await requestText(
    `${normalizeServerUrl(serverUrl)}/v1/sessions/${encodeURIComponent(sessionId)}/archive`,
    http.RequestMethod.POST,
    headers,
  );
  if (!response.ok) {
    throw new Error(parseHttpErrorMessage(response.text, `归档会话失败：${response.statusCode}`));
  }
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

function normalizeSpawnMachineSessionResult(value: Object): SpawnMachineSessionResult {
  const record = value as Record<string, Object>;
  const typeValue = record['type'];
  const type = typeof typeValue === 'string' ? typeValue : 'error';
  const sessionIdValue = record['sessionId'];
  const directoryValue = record['directory'];
  const errorMessageValue = record['errorMessage'];
  const errorValue = record['error'];
  const messageValue = record['message'];
  return {
    type,
    sessionId: typeof sessionIdValue === 'string' ? sessionIdValue : undefined,
    directory: typeof directoryValue === 'string' ? directoryValue : undefined,
    errorMessage: typeof errorMessageValue === 'string'
      ? errorMessageValue
      : typeof errorValue === 'string'
        ? errorValue
        : typeof messageValue === 'string'
          ? messageValue
          : undefined,
  };
}

function normalizeStopMachineDaemonResult(value: Object): StopMachineDaemonResult {
  const record = value as Record<string, Object>;
  const messageValue = record['message'];
  return {
    message: typeof messageValue === 'string' && messageValue.length > 0
      ? messageValue
      : '停止守护进程请求已发送',
  };
}

function normalizeCodexThreadListResult(value: Object): CodexThreadListResult {
  const record = value as Record<string, Object>;
  const threadsValue = record['threads'];
  const threads: CodexThreadSummary[] = [];
  if (Array.isArray(threadsValue)) {
    const threadItems = threadsValue as Object[];
    for (let index = 0; index < threadItems.length; index += 1) {
      const item = threadItems[index];
      if (item && typeof item === 'object') {
        const normalized = normalizeCodexThreadSummary(item as Object);
        if (normalized.id.length > 0) {
          threads.push(normalized);
        }
      }
    }
  }
  const nextCursorValue = record['nextCursor'];
  const backwardsCursorValue = record['backwardsCursor'];
  return {
    threads,
    nextCursor: typeof nextCursorValue === 'string' ? nextCursorValue : '',
    backwardsCursor: typeof backwardsCursorValue === 'string' ? backwardsCursorValue : '',
  };
}

function normalizeCodexThreadSummary(value: Object): CodexThreadSummary {
  const record = value as Record<string, Object>;
  return {
    id: readString(record, 'id'),
    name: readString(record, 'name'),
    preview: readString(record, 'preview'),
    cwd: readString(record, 'cwd'),
    path: readString(record, 'path'),
    source: stringifyValue(record['source']),
    modelProvider: readString(record, 'modelProvider'),
    cliVersion: readString(record, 'cliVersion'),
    createdAt: readNumber(record, 'createdAt'),
    updatedAt: readNumber(record, 'updatedAt'),
  };
}

function normalizeCodexThreadSyncResult(value: Object): CodexThreadSyncResult {
  const record = value as Record<string, Object>;
  const type = readString(record, 'type');
  const errorMessage = readString(record, 'errorMessage');
  return {
    type: type.length > 0 ? type : 'success',
    threadId: readString(record, 'threadId'),
    imported: readNumber(record, 'imported'),
    errorMessage: errorMessage.length > 0 ? errorMessage : undefined,
  };
}

function normalizeDirectoryListResult(value: Object): DirectoryListResult {
  const record = value as Record<string, Object>;
  const entriesValue = record['entries'];
  const entries: DirectoryEntrySummary[] = [];
  if (Array.isArray(entriesValue)) {
    const entryItems = entriesValue as Object[];
    for (let index = 0; index < entryItems.length; index += 1) {
      const item = entryItems[index];
      if (item && typeof item === 'object') {
        const normalized = normalizeDirectoryEntrySummary(item as Object);
        if (normalized.path.length > 0 && normalized.name.length > 0) {
          entries.push(normalized);
        }
      }
    }
  }
  const parentPathValue = record['parentPath'];
  const truncatedValue = record['truncated'];
  return {
    path: readString(record, 'path'),
    parentPath: typeof parentPathValue === 'string' ? parentPathValue : null,
    entries,
    truncated: typeof truncatedValue === 'boolean' ? truncatedValue : false,
  };
}

function normalizeDirectoryEntrySummary(value: Object): DirectoryEntrySummary {
  const record = value as Record<string, Object>;
  const hiddenValue = record['hidden'];
  return {
    name: readString(record, 'name'),
    path: readString(record, 'path'),
    type: readString(record, 'type'),
    hidden: typeof hiddenValue === 'boolean' ? hiddenValue : false,
  };
}

function readString(record: Record<string, Object>, key: string): string {
  const value = record[key];
  return typeof value === 'string' ? value : '';
}

function readNumber(record: Record<string, Object>, key: string): number {
  const value = record[key];
  return typeof value === 'number' ? value : 0;
}

function stringifyValue(value: Object): string {
  if (typeof value === 'string') {
    return value;
  }
  if (value && typeof value === 'object') {
    try {
      return JSON.stringify(value);
    } catch {
      return '';
    }
  }
  return '';
}

function stringifyError(error: Object): string {
  return `${error}`.replace(/^Error:\s*/, '');
}

function getCodexThreadAttachName(thread: CodexThreadSummary): string | null {
  const name = thread.name.trim();
  return name.length > 0 ? name : null;
}

async function sendRpc(
  serverUrl: string,
  credentials: Credentials,
  method: string,
  encryptedParams: string,
  label: string,
  timeoutMs: number = RPC_TIMEOUT_MS,
): Promise<RpcAckWire> {
  const body: RpcCallBody = {
    method,
    params: encryptedParams,
  };
  const ack = await sendSocketEventWithAck(serverUrl, credentials, 'rpc-call', body, label, timeoutMs);
  if (ack.ok === true) {
    return {
      ok: ack.ok,
      result: ack.result,
      error: ack.error,
    };
  }
  throw new Error(ack.error && ack.error.length > 0 ? ack.error : `${label} 调用失败`);
}

function sendSocketEventWithAck(
  serverUrl: string,
  credentials: Credentials,
  eventName: string,
  body: Object,
  label: string,
  timeoutMs: number = RPC_TIMEOUT_MS,
): Promise<SocketAckWire> {
  return new Promise<SocketAckWire>((resolve, reject) => {
    let done = false;
    let authenticated = false;
    const socket = webSocket.createWebSocket();
    const timerId = setTimeout((): void => {
      finish(new Error(`${label} 请求超时`));
    }, timeoutMs);

    const finish = (error: Error | null, result?: SocketAckWire): void => {
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
          console.error(`${label} 关闭失败：${closeError}`);
        });
      } catch (closeError) {
        console.error(`${label} 关闭失败：${closeError}`);
      }
      if (error) {
        reject(error);
      } else {
        resolve(result ?? { ok: true });
      }
    };

    const sendText = (text: string): void => {
      socket.send(text).catch((error: BusinessError) => {
        finish(new Error(`${label} 发送失败：${error}`));
      });
    };

    socket.on('message', (error: BusinessError, data: string | ArrayBuffer): void => {
      if (done) {
        return;
      }
      if (error) {
        finish(new Error(`${label} 接收失败：${error}`));
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
          sendText(buildSocketEventPacket(RPC_ACK_ID, eventName, body));
        }
      } else if (packet.startsWith('44')) {
        finish(new Error(`${label} 鉴权失败`));
      } else {
        const ack = parseSocketAck(packet, RPC_ACK_ID);
        if (ack) {
          finish(null, ack);
        }
      }
    });

    socket.on('close', (error: BusinessError): void => {
      if (!done) {
        finish(new Error(error ? `${label} 已断开：${error}` : `${label} 已断开`));
      }
    });

    socket.on('error', (error: BusinessError): void => {
      finish(new Error(`${label} 异常：${error}`));
    });

    try {
      socket.connect(buildSocketIoWebSocketUrl(serverUrl), {
        header: buildHeaders(),
      }).catch((error: BusinessError) => {
        finish(new Error(`${label} 连接失败：${error}`));
      });
    } catch (error) {
      finish(new Error(`${label} 连接异常：${error}`));
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

function buildSocketEventPacket(ackId: number, eventName: string, body: Object): string {
  return `42${ackId}${JSON.stringify([eventName, body])}`;
}

function parseSocketAck(packet: string, ackId: number): SocketAckWire | null {
  const prefix = `43${ackId}`;
  if (!packet.startsWith(prefix)) {
    return null;
  }
  try {
    const parsed = JSON.parse(packet.substring(prefix.length)) as Object;
    if (!Array.isArray(parsed) || parsed.length === 0) {
      return null;
    }
    return parsed[0] as SocketAckWire;
  } catch {
    return null;
  }
}

function getAckVersion(ack: SocketAckWire, label: string): number {
  if (typeof ack.version === 'number') {
    return ack.version;
  }
  throw new Error(`${label} 返回版本无效`);
}

function getAckMetadata(ack: SocketAckWire, fallback: string, label: string): string {
  if (typeof ack.metadata === 'string' && ack.metadata.length > 0) {
    return ack.metadata;
  }
  if (fallback.length > 0) {
    return fallback;
  }
  throw new Error(`${label} 返回数据无效`);
}

function getAckErrorMessage(ack: SocketAckWire, fallback: string): string {
  if (ack.message && ack.message.length > 0) {
    return ack.message;
  }
  if (ack.error && ack.error.length > 0) {
    return ack.error;
  }
  return fallback;
}

function buildMachineRenameMetadata(metadata: MachineMetadata | null, displayName: string): MachineMetadata {
  const next = cloneMetadata(metadata) as MachineMetadata;
  const trimmed = displayName.trim();
  next.displayName = trimmed.length > 0 ? trimmed : undefined;
  return next;
}

function buildSessionRenameMetadata(metadata: SessionMetadata | null, name: string): SessionMetadata {
  const next = cloneMetadata(metadata) as SessionMetadata;
  const trimmed = name.trim();
  next.name = trimmed.length > 0 ? trimmed : undefined;
  return next;
}

function cloneMetadata(metadata: Object | null): Object {
  if (!metadata) {
    return JSON.parse('{}') as Object;
  }
  return JSON.parse(JSON.stringify(metadata)) as Object;
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

async function requestText(url: string, method: http.RequestMethod, headers: Object): Promise<TextResponse> {
  const request = http.createHttp();
  try {
    const response = await request.request(url, {
      method,
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

function parseHttpErrorMessage(text: string, fallback: string): string {
  if (text.length === 0) {
    return fallback;
  }
  try {
    const parsed = JSON.parse(text) as Record<string, Object>;
    const error = parsed['error'];
    if (typeof error === 'string' && error.length > 0) {
      return error;
    }
  } catch {
    return text;
  }
  return fallback;
}
