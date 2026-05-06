import { describe, expect, it } from 'vitest';
import {
  createControlPlaneClient,
  buildSessionArchiveMetadata,
  buildMachineRenameMetadata,
  buildSessionRenameMetadata,
  filterVisibleSessions,
  mergeMachineSnapshotWithLocalMetadata,
  mergeSessionSnapshotWithLocalMetadata,
  buildMachineDetailRows,
  type ControlPlaneCredentials,
  formatMachineRowKey,
  formatMachineSubtitle,
  formatMachineTitle,
  listRecentMachineSessionPaths,
  resolveMachineSpawnPath,
  resolveCodexThreadListCwd,
  choosePreferredNewSessionAgent,
  filterNewSessionAgentOptionsForAvailability,
  formatSessionRowKey,
  formatSessionPath,
  formatSessionTitle,
  isSessionArchived,
  type ControlPlaneDecodeRequest,
} from './controlPlaneClient';

const credentials: ControlPlaneCredentials = {
  token: 'happy-token',
  secretBase64Url: 'secret',
};

describe('control plane client', () => {
  it('fetches machines and sessions with Happy auth headers and decodes encrypted fields', async () => {
    const requests: Array<{ url: string; headers: Record<string, string> }> = [];
    const decodeRequests: ControlPlaneDecodeRequest[] = [];
    const client = createControlPlaneClient({
      getServerUrl: () => 'https://happy.example.com/',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(url: string, headers: Record<string, string>): Promise<T> => {
        requests.push({ url, headers });
        if (url.endsWith('/v1/machines')) {
          return [
            {
              id: 'machine-1',
              seq: 7,
              createdAt: 1000,
              updatedAt: 2000,
              active: true,
              activeAt: 1900,
              metadata: 'encrypted-machine-metadata',
              metadataVersion: 2,
              daemonState: 'encrypted-daemon-state',
              daemonStateVersion: 3,
              dataEncryptionKey: 'machine-data-key',
            },
          ] as T;
        }
        return {
          sessions: [
            {
              id: 'session-1',
              seq: 9,
              createdAt: 3000,
              updatedAt: 4000,
              active: false,
              activeAt: 3500,
              metadata: 'encrypted-session-metadata',
              metadataVersion: 4,
              agentState: 'encrypted-agent-state',
              agentStateVersion: 5,
              dataEncryptionKey: null,
              lastMessage: null,
            },
          ],
        } as T;
      },
      decodeRecord: async (request) => {
        decodeRequests.push(request);
        if (request.encrypted === 'encrypted-machine-metadata') {
          return {
            host: 'workstation',
            platform: 'darwin',
            happyCliVersion: '1.1.8',
            displayName: 'Mac Studio',
          };
        }
        if (request.encrypted === 'encrypted-daemon-state') {
          return { pid: 12345 };
        }
        if (request.encrypted === 'encrypted-session-metadata') {
          return {
            path: '/Users/tengyi/project',
            host: 'workstation',
            summary: { text: '修复移动端同步', updatedAt: 3900 },
          };
        }
        if (request.encrypted === 'encrypted-agent-state') {
          return { requests: { approve_1: { tool: 'bash', arguments: {}, createdAt: 3800 } } };
        }
        return null;
      },
    });

    const snapshot = await client.fetchSnapshot(credentials);

    expect(requests).toEqual([
      {
        url: 'https://happy.example.com/v1/machines',
        headers: {
          Authorization: 'Bearer happy-token',
          'Content-Type': 'application/json',
          'X-Happy-Client': 'harmony/0.1.0',
        },
      },
      {
        url: 'https://happy.example.com/v1/sessions',
        headers: {
          Authorization: 'Bearer happy-token',
          'Content-Type': 'application/json',
          'X-Happy-Client': 'harmony/0.1.0',
        },
      },
    ]);
    expect(decodeRequests).toEqual([
      {
        encrypted: 'encrypted-machine-metadata',
        dataEncryptionKey: 'machine-data-key',
        kind: 'machine-metadata',
      },
      {
        encrypted: 'encrypted-daemon-state',
        dataEncryptionKey: 'machine-data-key',
        kind: 'machine-daemon-state',
      },
      {
        encrypted: 'encrypted-session-metadata',
        dataEncryptionKey: null,
        kind: 'session-metadata',
      },
      {
        encrypted: 'encrypted-agent-state',
        dataEncryptionKey: null,
        kind: 'session-agent-state',
      },
    ]);
    expect(snapshot.machines[0]).toMatchObject({
      id: 'machine-1',
      active: true,
      metadata: { host: 'workstation', displayName: 'Mac Studio' },
      daemonState: { pid: 12345 },
    });
    expect(snapshot.sessions[0]).toMatchObject({
      id: 'session-1',
      active: false,
      metadata: { summary: { text: '修复移动端同步' } },
      agentState: { requests: { approve_1: { tool: 'bash' } } },
    });
  });

  it('rejects an empty token before issuing network requests', async () => {
    let requested = false;
    const client = createControlPlaneClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(): Promise<T> => {
        requested = true;
        return {} as T;
      },
      decodeRecord: async () => null,
    });

    await expect(client.fetchSnapshot({ ...credentials, token: '' })).rejects.toThrow('Auth token is empty');
    expect(requested).toBe(false);
  });

  it('rejects malformed machine responses with a protocol error', async () => {
    const client = createControlPlaneClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(): Promise<T> => ({ error: 'not an array' }) as T,
      decodeRecord: async () => null,
    });

    await expect(client.fetchSnapshot(credentials)).rejects.toThrow('Machine list response has an invalid shape');
  });

  it('rejects malformed session responses with a protocol error', async () => {
    const client = createControlPlaneClient({
      getServerUrl: () => 'https://happy.example.com',
      getHappyClientId: () => 'harmony/0.1.0',
      getJson: async <T>(url: string): Promise<T> => {
        if (url.endsWith('/v1/machines')) {
          return [] as T;
        }
        return { sessions: null } as T;
      },
      decodeRecord: async () => null,
    });

    await expect(client.fetchSnapshot(credentials)).rejects.toThrow('Session list response has an invalid shape');
  });

  it('formats machine and session titles using Android-compatible metadata fallbacks', () => {
    expect(formatMachineTitle({ id: 'm1', metadata: { displayName: '工作电脑', host: 'mac-mini' } })).toBe('工作电脑');
    expect(formatMachineTitle({ id: 'm1', metadata: { host: 'mac-mini' } })).toBe('mac-mini');
    expect(formatMachineSubtitle({ metadata: { platform: 'darwin', happyCliVersion: '1.1.8' }, active: true })).toBe(
      '在线 · darwin · CLI 1.1.8',
    );
    expect(formatSessionTitle({
      id: 's1',
      metadata: { name: '自定义会话名', summary: { text: '实现机器列表', updatedAt: 1 }, path: '/tmp/happy' },
    })).toBe('自定义会话名');
    expect(formatSessionTitle({ id: 's1', metadata: { summary: { text: '实现机器列表', updatedAt: 1 }, path: '/tmp/happy' } }))
      .toBe('实现机器列表');
    expect(formatSessionTitle({ id: 's1', metadata: { path: '/tmp/happy' } })).toBe('happy');
  });

  it('formats session paths with a compact home-relative tail', () => {
    expect(formatSessionPath('/Users/tengyi/uniubi/work/IdeaProjects/happy')).toBe('~/.../IdeaProjects/happy');
    expect(formatSessionPath('/Users/tengyi/project')).toBe('~/project');
    expect(formatSessionPath('/srv/builds/uniubi/work/happy')).toBe('/.../work/happy');
    expect(formatSessionPath('/custom/home/project', '/custom/home')).toBe('~/project');
  });

  it('builds rename metadata without dropping existing fields', () => {
    expect(buildMachineRenameMetadata({
      host: 'mac-mini',
      platform: 'darwin',
      displayName: '旧名称',
    }, ' 工作台 ')).toEqual({
      host: 'mac-mini',
      platform: 'darwin',
      displayName: '工作台',
    });
    expect(buildMachineRenameMetadata({ host: 'mac-mini', displayName: '旧名称' }, '   ')).toEqual({
      host: 'mac-mini',
      displayName: undefined,
    });
    expect(buildSessionRenameMetadata({
      path: '/Users/tengyi/project',
      host: 'mac-mini',
      name: '旧会话',
      summary: { text: '旧摘要', updatedAt: 1 },
    }, ' 新会话 ')).toEqual({
      path: '/Users/tengyi/project',
      host: 'mac-mini',
      name: '新会话',
      summary: { text: '旧摘要', updatedAt: 1 },
    });
    expect(buildSessionRenameMetadata({
      path: '/Users/tengyi/project',
      name: '旧会话',
      summary: { text: '旧摘要', updatedAt: 1 },
    }, '')).toEqual({
      path: '/Users/tengyi/project',
      name: undefined,
      summary: { text: '旧摘要', updatedAt: 1 },
    });
  });

  it('builds archive metadata and hides archived sessions from terminal lists', () => {
    const archivedMetadata = buildSessionArchiveMetadata({
      path: '/Users/tengyi/project',
      name: '导入 Codex 会话',
      lifecycleState: 'running',
      lifecycleStateSince: 10,
      archivedBy: undefined,
    }, 200);

    expect(archivedMetadata).toEqual({
      path: '/Users/tengyi/project',
      name: '导入 Codex 会话',
      lifecycleState: 'archiveRequested',
      lifecycleStateSince: 200,
      archivedBy: 'harmony',
      archiveReason: 'User archived from Harmony',
    });

    const sessions = [
      {
        id: 'visible',
        seq: 1,
        createdAt: 1,
        updatedAt: 10,
        active: true,
        activeAt: 10,
        metadata: { lifecycleState: 'running' },
        metadataVersion: 1,
        agentState: null,
        agentStateVersion: 1,
        dataEncryptionKey: null,
      },
      {
        id: 'archive-requested',
        seq: 2,
        createdAt: 2,
        updatedAt: 20,
        active: true,
        activeAt: 20,
        metadata: { lifecycleState: 'archiveRequested' },
        metadataVersion: 2,
        agentState: null,
        agentStateVersion: 1,
        dataEncryptionKey: null,
      },
      {
        id: 'archived',
        seq: 3,
        createdAt: 3,
        updatedAt: 30,
        active: false,
        activeAt: 30,
        metadata: { lifecycleState: 'archived' },
        metadataVersion: 3,
        agentState: null,
        agentStateVersion: 1,
        dataEncryptionKey: null,
      },
      {
        id: 'inactive-visible',
        seq: 4,
        createdAt: 4,
        updatedAt: 40,
        active: false,
        activeAt: 40,
        metadata: { lifecycleState: 'running' },
        metadataVersion: 4,
        agentState: null,
        agentStateVersion: 1,
        dataEncryptionKey: null,
      },
    ];

    expect(isSessionArchived(sessions[0])).toBe(false);
    expect(isSessionArchived(sessions[1])).toBe(true);
    expect(isSessionArchived(sessions[2])).toBe(true);
    expect(isSessionArchived(sessions[3])).toBe(false);
    expect(filterVisibleSessions(sessions).map((session) => session.id)).toEqual(['visible', 'inactive-visible']);
  });

  it('keeps newer local rename metadata when an older snapshot arrives after save', () => {
    const machines = mergeMachineSnapshotWithLocalMetadata([
      {
        id: 'm1',
        seq: 1,
        createdAt: 1,
        updatedAt: 10,
        active: true,
        activeAt: 10,
        metadata: { displayName: '新设备名', host: 'mac-mini' },
        metadataVersion: 3,
        daemonState: { pid: 111 },
        daemonStateVersion: 1,
        dataEncryptionKey: 'key',
      },
    ], [
      {
        id: 'm1',
        seq: 1,
        createdAt: 1,
        updatedAt: 12,
        active: false,
        activeAt: 12,
        metadata: { displayName: '旧设备名', host: 'mac-mini' },
        metadataVersion: 2,
        daemonState: { pid: 222 },
        daemonStateVersion: 2,
        dataEncryptionKey: 'key',
      },
    ]);

    expect(machines[0]).toMatchObject({
      active: false,
      activeAt: 12,
      metadata: { displayName: '新设备名', host: 'mac-mini' },
      metadataVersion: 3,
      daemonState: { pid: 222 },
      daemonStateVersion: 2,
    });

    const sessions = mergeSessionSnapshotWithLocalMetadata([
      {
        id: 's1',
        seq: 1,
        createdAt: 1,
        updatedAt: 10,
        active: true,
        activeAt: 10,
        metadata: { name: '新会话名', summary: { text: '旧摘要', updatedAt: 1 } },
        metadataVersion: 5,
        agentState: { status: 'local' },
        agentStateVersion: 1,
        dataEncryptionKey: 'key',
      },
    ], [
      {
        id: 's1',
        seq: 1,
        createdAt: 1,
        updatedAt: 12,
        active: false,
        activeAt: 12,
        metadata: { summary: { text: '旧摘要', updatedAt: 1 } },
        metadataVersion: 4,
        agentState: { status: 'remote' },
        agentStateVersion: 2,
        dataEncryptionKey: 'key',
      },
    ]);

    expect(sessions[0]).toMatchObject({
      active: false,
      activeAt: 12,
      metadata: { name: '新会话名', summary: { text: '旧摘要', updatedAt: 1 } },
      metadataVersion: 5,
      agentState: { status: 'remote' },
      agentStateVersion: 2,
    });
  });

  it('changes list row keys when metadata or activity versions change', () => {
    expect(formatMachineRowKey({
      id: 'm1',
      active: true,
      activeAt: 10,
      metadataVersion: 2,
      daemonStateVersion: 1,
    })).not.toBe(formatMachineRowKey({
      id: 'm1',
      active: true,
      activeAt: 10,
      metadataVersion: 3,
      daemonStateVersion: 1,
    }));
    expect(formatSessionRowKey({
      id: 's1',
      active: false,
      activeAt: 10,
      thinking: false,
      thinkingAt: 0,
      metadataVersion: 4,
      agentStateVersion: 1,
    })).not.toBe(formatSessionRowKey({
      id: 's1',
      active: false,
      activeAt: 10,
      thinking: false,
      thinkingAt: 0,
      metadataVersion: 5,
      agentStateVersion: 1,
    }));
  });

  it('builds Android-compatible machine detail rows', () => {
    const rows = buildMachineDetailRows({
      id: 'm1',
      seq: 1,
      createdAt: 1000,
      updatedAt: 2000,
      active: true,
      activeAt: 3000,
      metadataVersion: 2,
      daemonStateVersion: 3,
      dataEncryptionKey: null,
      metadata: {
        host: 'tiancang.local',
        username: 'tengyi',
        platform: 'darwin',
        arch: 'arm64',
        homeDir: '/Users/tengyi',
        happyHomeDir: '/Users/tengyi/.happy',
        happyCliVersion: '1.1.8',
        cliAvailability: {
          claude: false,
          codex: true,
          gemini: false,
          openclaw: true,
          detectedAt: 4000,
        },
      },
      daemonState: {
        pid: 12345,
        httpPort: 3005,
        startedWithCliVersion: '1.1.8',
      },
    });

    expect(rows.map((row) => `${row.group}:${row.label}`)).toContain('终端:主机');
    expect(rows.map((row) => `${row.group}:${row.label}`)).toContain('守护进程:最后 PID');
    expect(rows.find((row) => row.label === 'Codex')?.value).toBe('已安装');
  });

  it('treats a shutting-down daemon as stopped even while the machine activity flag is active', () => {
    const rows = buildMachineDetailRows({
      id: 'm1',
      seq: 1,
      createdAt: 1000,
      updatedAt: 2000,
      active: true,
      activeAt: 3000,
      metadataVersion: 2,
      daemonStateVersion: 3,
      dataEncryptionKey: null,
      metadata: {
        host: 'tiancang.local',
        daemonLastKnownStatus: 'shutting-down',
      },
      daemonState: null,
    });

    expect(rows.find((row) => row.group === '守护进程' && row.label === '状态')?.value).toBe('已停止');
  });

  it('lists recent machine session paths by activity without duplicates', () => {
    const paths = listRecentMachineSessionPaths([
      { updatedAt: 10, metadata: { machineId: 'm1', path: '/Users/tengyi/old' } },
      { updatedAt: 30, metadata: { machineId: 'm1', path: '/Users/tengyi/new' } },
      { updatedAt: 40, metadata: { machineId: 'm2', path: '/Users/tengyi/other-machine' } },
      { updatedAt: 20, metadata: { machineId: 'm1', path: '/Users/tengyi/old' } },
      { updatedAt: 50, metadata: { machineId: 'm1', path: '   ' } },
    ], 'm1');

    expect(paths).toEqual(['/Users/tengyi/new', '/Users/tengyi/old']);
  });

  it('resolves home-relative spawn paths against machine metadata', () => {
    expect(resolveMachineSpawnPath('~', '/Users/tengyi')).toBe('/Users/tengyi');
    expect(resolveMachineSpawnPath('~/work/happy', '/Users/tengyi')).toBe('/Users/tengyi/work/happy');
    expect(resolveMachineSpawnPath('/tmp/happy', '/Users/tengyi')).toBe('/tmp/happy');
    expect(resolveMachineSpawnPath('~/work/happy', '')).toBe('~/work/happy');
  });

  it('builds Codex thread list cwd from the selected machine path', () => {
    expect(resolveCodexThreadListCwd('~/work/happy', '/Users/tengyi')).toBe('/Users/tengyi/work/happy');
    expect(resolveCodexThreadListCwd('/tmp/happy', '/Users/tengyi')).toBe('/tmp/happy');
    expect(resolveCodexThreadListCwd('   ', '/Users/tengyi')).toBeNull();
  });

  it('prefers Codex for new sessions when it is available', () => {
    expect(choosePreferredNewSessionAgent([
      { key: 'claude' },
      { key: 'codex' },
      { key: 'gemini' },
    ])).toBe('codex');
    expect(choosePreferredNewSessionAgent([
      { key: 'claude' },
      { key: 'gemini' },
    ])).toBe('claude');
    expect(choosePreferredNewSessionAgent([])).toBe('');
  });

  it('keeps unknown CLI availability optimistic but honors explicit unavailable agents', () => {
    const options = [
      { key: 'claude' },
      { key: 'codex' },
      { key: 'gemini' },
      { key: 'openclaw' },
    ];

    expect(filterNewSessionAgentOptionsForAvailability(options, null).map((option) => option.key)).toEqual([
      'claude',
      'codex',
      'gemini',
      'openclaw',
    ]);
    expect(filterNewSessionAgentOptionsForAvailability(options, {
      claude: false,
      codex: false,
      gemini: false,
      openclaw: false,
    })).toEqual([]);
    expect(filterNewSessionAgentOptionsForAvailability(options, {
      claude: false,
      codex: true,
      gemini: false,
      openclaw: false,
    }).map((option) => option.key)).toEqual(['codex']);
  });
});
