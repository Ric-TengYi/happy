import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  buildSessionPermissionRequest,
  buildSocketIoRpcCallPacket,
  parseSocketIoRpcAckPacket,
} from './sessionRpc';

const testDir = dirname(fileURLToPath(import.meta.url));
const sessionRpcServiceSource = readFileSync(resolve(testDir, '../../entry/src/main/ets/services/HappySessionRpc.ets'), 'utf8');

describe('session rpc helpers', () => {
  it('builds a Socket.IO rpc-call packet with an ack id', () => {
    expect(buildSocketIoRpcCallPacket(7, {
      method: 'session-1:permission',
      params: 'encrypted-params',
    })).toBe('427["rpc-call",{"method":"session-1:permission","params":"encrypted-params"}]');
  });

  it('parses only the matching Socket.IO rpc ack packet', () => {
    expect(parseSocketIoRpcAckPacket('438[{"ok":true,"result":"encrypted-result"}]', 8)).toEqual({
      ok: true,
      result: 'encrypted-result',
    });
    expect(parseSocketIoRpcAckPacket('439[{"ok":true}]', 8)).toBeNull();
    expect(parseSocketIoRpcAckPacket('428["update",{}]', 8)).toBeNull();
  });

  it('builds Android-compatible permission request payloads', () => {
    expect(buildSessionPermissionRequest({
      id: 'tool-1',
      approved: true,
      decision: 'approved_for_session',
      allowTools: ['Bash(pnpm test)'],
    })).toEqual({
      id: 'tool-1',
      approved: true,
      allowTools: ['Bash(pnpm test)'],
      decision: 'approved_for_session',
    });

    expect(buildSessionPermissionRequest({
      id: 'tool-2',
      approved: false,
      decision: 'abort',
    })).toEqual({
      id: 'tool-2',
      approved: false,
      decision: 'abort',
    });
  });

  it('keeps Harmony Codex history sync wired to the machine RPC method', () => {
    expect(sessionRpcServiceSource).toContain('export async function syncCodexThread(');
    expect(sessionRpcServiceSource).toContain('CodexThreadSyncRequest');
    expect(sessionRpcServiceSource).toContain("`${machine.id}:codex-thread-sync`");
    expect(sessionRpcServiceSource).toContain('MACHINE_CODEX_SYNC_RPC_TIMEOUT_MS');
    expect(sessionRpcServiceSource).toContain('normalizeCodexThreadSyncResult');
  });
});
