import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiMachineClient } from './apiMachine';
import { decodeBase64, decrypt, encodeBase64, encrypt } from './encryption';

vi.mock('socket.io-client', () => ({
    io: vi.fn(),
}));

vi.mock('@/ui/logger', () => ({
    logger: {
        debug: vi.fn(),
        debugLargeJson: vi.fn(),
    },
}));

vi.mock('@/configuration', () => ({
    configuration: {
        serverUrl: 'https://server.test',
        currentCliVersion: '0.0.0-test',
    },
}));

vi.mock('@/modules/common/registerCommonHandlers', () => ({
    registerCommonHandlers: vi.fn(),
}));

vi.mock('@/utils/detectCLI', () => ({
    detectCLIAvailability: vi.fn(() => ({ claude: true, codex: true, gemini: false, openclaw: false, detectedAt: 1 })),
}));

vi.mock('@/resume/localHappyAgentAuth', () => ({
    detectResumeSupport: vi.fn(() => ({ rpcAvailable: true, happyAgentAuthenticated: true })),
}));

vi.mock('@/utils/lidState', () => ({
    shouldReconnect: vi.fn(() => true),
}));

function makeMachine() {
    return {
        id: 'machine-1',
        encryptionKey: new Uint8Array(32),
        encryptionVariant: 'legacy' as const,
        metadata: null,
        metadataVersion: 0,
        daemonState: null,
        daemonStateVersion: 0,
    };
}

async function callEncryptedMachineRpc(client: ApiMachineClient, machine: ReturnType<typeof makeMachine>, method: string, params: unknown): Promise<unknown> {
    const request = {
        method: `${machine.id}:${method}`,
        params: encodeBase64(encrypt(machine.encryptionKey, machine.encryptionVariant, params)),
    };
    const encoded = await (client as any).rpcHandlerManager.handleRequest(request);
    return decrypt(machine.encryptionKey, machine.encryptionVariant, decodeBase64(encoded));
}

describe('ApiMachineClient Codex machine RPC handlers', () => {
    beforeEach(() => {
        vi.clearAllMocks();
    });

    it('routes encrypted codex-thread-list requests to the configured handler', async () => {
        const machine = makeMachine();
        const listCodexThreads = vi.fn(async () => ({
            threads: [{ id: 'thread-1', name: 'Codex thread' }],
            nextCursor: null,
            backwardsCursor: null,
        }));
        const client = new ApiMachineClient('token', machine as any);

        client.setRPCHandlers({
            spawnSession: vi.fn(),
            listCodexThreads,
            stopSession: vi.fn(() => true),
            requestShutdown: vi.fn(),
        });

        const response = await callEncryptedMachineRpc(client, machine, 'codex-thread-list', {
            limit: 5,
            searchTerm: 'Codex',
            archived: false,
        });

        expect(listCodexThreads).toHaveBeenCalledWith({
            cursor: null,
            limit: 5,
            cwd: null,
            searchTerm: 'Codex',
            archived: false,
        });
        expect(response).toEqual({
            threads: [{ id: 'thread-1', name: 'Codex thread' }],
            nextCursor: null,
            backwardsCursor: null,
        });
    });

    it('routes encrypted codex-thread-attach requests and returns spawned session id', async () => {
        const machine = makeMachine();
        const attachCodexThread = vi.fn(async () => ({
            type: 'success' as const,
            sessionId: 'happy-session-1',
        }));
        const client = new ApiMachineClient('token', machine as any);

        client.setRPCHandlers({
            spawnSession: vi.fn(),
            attachCodexThread,
            stopSession: vi.fn(() => true),
            requestShutdown: vi.fn(),
        });

        const response = await callEncryptedMachineRpc(client, machine, 'codex-thread-attach', {
            threadId: 'thread-1',
            cwd: '/tmp/project',
            threadName: '修复 Harmony 会话列表',
        });

        expect(attachCodexThread).toHaveBeenCalledWith({
            threadId: 'thread-1',
            cwd: '/tmp/project',
            threadName: '修复 Harmony 会话列表',
        });
        expect(response).toEqual({
            type: 'success',
            sessionId: 'happy-session-1',
        });
    });

    it('routes encrypted codex-thread-sync requests to the configured handler', async () => {
        const machine = makeMachine();
        const syncCodexThread = vi.fn(async () => ({
            type: 'success' as const,
            threadId: 'thread-1',
            imported: 3,
        }));
        const client = new ApiMachineClient('token', machine as any);

        client.setRPCHandlers({
            spawnSession: vi.fn(),
            syncCodexThread,
            stopSession: vi.fn(() => true),
            requestShutdown: vi.fn(),
        });

        const response = await callEncryptedMachineRpc(client, machine, 'codex-thread-sync', {
            happySessionId: 'happy-session-1',
            threadId: 'thread-1',
        });

        expect(syncCodexThread).toHaveBeenCalledWith({
            happySessionId: 'happy-session-1',
            threadId: 'thread-1',
        });
        expect(response).toEqual({
            type: 'success',
            threadId: 'thread-1',
            imported: 3,
        });
    });

    it('routes encrypted directory-list requests to the configured handler', async () => {
        const machine = makeMachine();
        const listDirectories = vi.fn(async () => ({
            path: '/Users/tengyi',
            parentPath: '/Users',
            entries: [{ name: 'work', path: '/Users/tengyi/work', type: 'directory' as const, hidden: false }],
            truncated: false,
        }));
        const client = new ApiMachineClient('token', machine as any);

        client.setRPCHandlers({
            spawnSession: vi.fn(),
            listDirectories,
            stopSession: vi.fn(() => true),
            requestShutdown: vi.fn(),
        });

        const response = await callEncryptedMachineRpc(client, machine, 'directory-list', {
            path: '/Users/tengyi',
            showHidden: true,
            limit: 25,
        });

        expect(listDirectories).toHaveBeenCalledWith({
            path: '/Users/tengyi',
            showHidden: true,
            limit: 25,
        });
        expect(response).toEqual({
            path: '/Users/tengyi',
            parentPath: '/Users',
            entries: [{ name: 'work', path: '/Users/tengyi/work', type: 'directory', hidden: false }],
            truncated: false,
        });
    });
});
