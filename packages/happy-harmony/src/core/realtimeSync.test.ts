import { describe, expect, it } from 'vitest';
import {
  applyRealtimeEvent,
  buildSocketIoAuthPacket,
  buildSocketIoWebSocketUrl,
  parseSocketIoPacket,
  shouldRefreshSelectedSessionMessages,
  type RealtimeSnapshot,
} from './realtimeSync';

const snapshot: RealtimeSnapshot = {
  machines: [
    {
      id: 'machine-1',
      seq: 1,
      createdAt: 1000,
      updatedAt: 2000,
      active: false,
      activeAt: 1500,
      metadata: { host: 'mac-mini' },
      metadataVersion: 1,
      daemonState: null,
      daemonStateVersion: 0,
      dataEncryptionKey: null,
    },
  ],
  sessions: [
    {
      id: 'session-1',
      seq: 2,
      createdAt: 3000,
      updatedAt: 4000,
      active: false,
      activeAt: 3500,
      metadata: { path: '/tmp/happy', host: 'mac-mini' },
      metadataVersion: 1,
      agentState: null,
      agentStateVersion: 0,
      dataEncryptionKey: null,
    },
  ],
};

describe('realtime sync protocol helpers', () => {
  it('builds the Android-compatible Socket.IO websocket URL', () => {
    expect(buildSocketIoWebSocketUrl('https://47.118.25.177/')).toBe(
      'wss://47.118.25.177/v1/updates/?EIO=4&transport=websocket',
    );
    expect(buildSocketIoWebSocketUrl('http://127.0.0.1:3005')).toBe(
      'ws://127.0.0.1:3005/v1/updates/?EIO=4&transport=websocket',
    );
  });

  it('builds the Socket.IO namespace auth packet used by user-scoped clients', () => {
    expect(buildSocketIoAuthPacket({
      token: 'happy-token',
      happyClient: 'harmony/0.1.0',
    })).toBe('40{"token":"happy-token","clientType":"user-scoped","happyClient":"harmony/0.1.0"}');
  });

  it('parses Engine.IO ping and Socket.IO update events', () => {
    expect(parseSocketIoPacket('2')).toEqual({ type: 'engine-ping' });
    expect(parseSocketIoPacket('40{"sid":"server-socket-id"}')).toEqual({ type: 'socket-connected' });
    expect(parseSocketIoPacket('42["update",{"id":"event-1","seq":9,"createdAt":1234,"body":{"t":"new-session","id":"session-2"}}]')).toEqual({
      type: 'update',
      update: {
        id: 'event-1',
        seq: 9,
        createdAt: 1234,
        body: {
          t: 'new-session',
          id: 'session-2',
        },
      },
    });
  });

  it('patches known machine and session activity without forcing a snapshot refresh', () => {
    const machineResult = applyRealtimeEvent(snapshot, {
      type: 'ephemeral',
      event: { type: 'machine-activity', id: 'machine-1', active: true, activeAt: 5000 },
    });
    expect(machineResult.needsRefresh).toBe(false);
    expect(machineResult.snapshot.machines[0]).toMatchObject({ active: true, activeAt: 5000 });
    expect(machineResult.snapshot.sessions[0]).toBe(snapshot.sessions[0]);

    const sessionResult = applyRealtimeEvent(snapshot, {
      type: 'ephemeral',
      event: { type: 'activity', id: 'session-1', active: true, activeAt: 6000, thinking: true },
    });
    expect(sessionResult.needsRefresh).toBe(false);
    expect(sessionResult.snapshot.sessions[0]).toMatchObject({ active: true, activeAt: 6000, thinking: true, thinkingAt: 6000 });
    expect(sessionResult.snapshot.machines[0]).toBe(snapshot.machines[0]);
  });

  it('requests a snapshot refresh for unknown activity, durable updates, and reconnect catch-up', () => {
    expect(applyRealtimeEvent(snapshot, {
      type: 'ephemeral',
      event: { type: 'machine-activity', id: 'missing-machine', active: true, activeAt: 7000 },
    })).toMatchObject({ needsRefresh: true, reason: 'unknown-machine' });

    expect(applyRealtimeEvent(snapshot, {
      type: 'update',
      update: { id: 'event-2', seq: 10, createdAt: 8000, body: { t: 'update-machine', machineId: 'machine-1' } },
    })).toMatchObject({ needsRefresh: true, reason: 'durable-update' });

    expect(applyRealtimeEvent(snapshot, { type: 'socket-connected' })).toMatchObject({
      needsRefresh: true,
      reason: 'reconnect-catch-up',
    });
  });

  it('requests selected session message refresh after encrypted session state changes', () => {
    const nextSnapshot: RealtimeSnapshot = {
      machines: snapshot.machines,
      sessions: [
        {
          ...snapshot.sessions[0],
          updatedAt: 9000,
          agentStateVersion: 1,
          agentState: { requests: { approval_1: { tool: 'CodexBash' } } },
        },
      ],
    };

    expect(shouldRefreshSelectedSessionMessages(
      snapshot.sessions,
      nextSnapshot.sessions,
      'session-1',
    )).toBe(true);
  });

  it('does not request selected session message refresh for plain activity metadata changes', () => {
    const nextSnapshot: RealtimeSnapshot = {
      machines: snapshot.machines,
      sessions: [
        {
          ...snapshot.sessions[0],
          updatedAt: 9000,
          metadataVersion: 2,
        },
      ],
    };

    expect(shouldRefreshSelectedSessionMessages(
      snapshot.sessions,
      nextSnapshot.sessions,
      'session-1',
    )).toBe(false);
  });
});
