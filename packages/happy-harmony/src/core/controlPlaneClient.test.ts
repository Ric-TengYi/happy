import { describe, expect, it } from 'vitest';
import {
  createControlPlaneClient,
  type ControlPlaneCredentials,
  formatMachineSubtitle,
  formatMachineTitle,
  formatSessionTitle,
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
    expect(formatSessionTitle({ id: 's1', metadata: { summary: { text: '实现机器列表', updatedAt: 1 }, path: '/tmp/happy' } })).toBe(
      '实现机器列表',
    );
    expect(formatSessionTitle({ id: 's1', metadata: { path: '/tmp/happy' } })).toBe('happy');
  });
});
