import { describe, expect, it, vi } from 'vitest';

import { importCodexThreadHistory } from './importThreadHistory';

describe('importCodexThreadHistory', () => {
    it('reads a Codex thread and writes deterministic Happy session messages', async () => {
        const client = {
            readThread: vi.fn().mockResolvedValue({
                thread: {
                    id: 'thread-1',
                    turns: [{
                        id: 'turn-1',
                        startedAt: 100,
                        items: [
                            {
                                type: 'userMessage',
                                id: 'user-1',
                                content: [{ type: 'text', text: 'hello' }],
                            },
                            {
                                type: 'agentMessage',
                                id: 'agent-1',
                                text: 'world',
                            },
                        ],
                    }],
                },
            }),
        };
        const session = {
            sendSessionProtocolMessage: vi.fn(),
            flushPendingMessages: vi.fn(),
        };

        const result = await importCodexThreadHistory({
            client,
            session,
            threadId: 'thread-1',
        });

        expect(client.readThread).toHaveBeenCalledWith({
            threadId: 'thread-1',
            includeTurns: true,
        });
        expect(session.sendSessionProtocolMessage).toHaveBeenCalledTimes(2);
        expect(session.sendSessionProtocolMessage).toHaveBeenNthCalledWith(
            1,
            expect.objectContaining({ role: 'user', ev: { t: 'text', text: 'hello' } }),
            { localId: 'codex-import:thread-1:turn-1:user-1', invalidate: false },
        );
        expect(session.sendSessionProtocolMessage).toHaveBeenNthCalledWith(
            2,
            expect.objectContaining({ role: 'agent', ev: { t: 'text', text: 'world' } }),
            { localId: 'codex-import:thread-1:turn-1:agent-1', invalidate: false },
        );
        expect(session.flushPendingMessages).toHaveBeenCalledTimes(1);
        expect(result).toEqual({
            threadId: 'thread-1',
            imported: 2,
        });
    });
});
