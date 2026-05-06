import { describe, expect, it } from 'vitest';
import { mapCodexThreadToSessionProtocolMessages } from './historyImport';

describe('mapCodexThreadToSessionProtocolMessages', () => {
    it('maps Codex turns into deterministic Happy session protocol messages', () => {
        const messages = mapCodexThreadToSessionProtocolMessages({
            id: 'thread-1',
            name: 'Imported thread',
            preview: 'preview',
            cwd: '/tmp/project',
            turns: [{
                id: 'turn-1',
                startedAt: 100,
                completedAt: 101,
                status: { type: 'completed' },
                items: [
                    {
                        type: 'userMessage',
                        id: 'user-1',
                        content: [{ type: 'text', text: 'hello Codex', text_elements: [] }],
                    },
                    {
                        type: 'commandExecution',
                        id: 'cmd-1',
                        command: 'pwd',
                        cwd: '/tmp/project',
                        source: { type: 'exec' },
                        status: { type: 'completed' },
                        commandActions: [],
                        aggregatedOutput: '/tmp/project\n',
                        exitCode: 0,
                        durationMs: 10,
                    },
                    {
                        type: 'agentMessage',
                        id: 'agent-1',
                        text: 'done',
                        phase: 'final_answer',
                        memoryCitation: null,
                    },
                ],
            }],
        });

        expect(messages.map((message) => message.localId)).toEqual([
            'codex-import:thread-1:turn-1:user-1',
            'codex-import:thread-1:turn-1:agent-1',
        ]);
        expect(messages.map((message) => message.envelope.ev.t)).toEqual([
            'text',
            'text',
        ]);
        expect(messages[0].envelope).toEqual(expect.objectContaining({
            role: 'user',
            turn: 'codex-import:thread-1:turn-1',
            ev: { t: 'text', text: 'hello Codex' },
        }));
        expect(messages[1].envelope).toEqual(expect.objectContaining({
            role: 'agent',
            ev: { t: 'text', text: 'done' },
        }));
    });

    it('keeps the most recent Codex turns when imported history is long', () => {
        const turns = Array.from({ length: 50 }, (_, index) => ({
            id: `turn-${index + 1}`,
            startedAt: index + 1,
            completedAt: index + 2,
            status: { type: 'completed' },
            items: [
                {
                    type: 'userMessage',
                    id: `user-${index + 1}`,
                    content: [{ type: 'text', text: `question ${index + 1}`, text_elements: [] }],
                },
                {
                    type: 'agentMessage',
                    id: `agent-${index + 1}`,
                    text: `answer ${index + 1}`,
                    phase: 'final_answer',
                    memoryCitation: null,
                },
            ],
        }));

        const messages = mapCodexThreadToSessionProtocolMessages({
            id: 'thread-long',
            turns,
        });

        expect(messages.length).toBeLessThanOrEqual(80);
        expect(messages.some((message) => message.localId.startsWith('codex-import:thread-long:turn-1:'))).toBe(false);
        expect(messages.some((message) => message.localId.startsWith('codex-import:thread-long:turn-50:'))).toBe(true);
        expect(messages[messages.length - 1].envelope.ev).toEqual({ t: 'text', text: 'answer 50' });
    });

    it('uses deterministic fallback times when Codex turns have no timestamps', () => {
        const messages = mapCodexThreadToSessionProtocolMessages({
            id: 'thread-no-time',
            turns: [{
                id: 'turn-no-time',
                items: [{
                    type: 'agentMessage',
                    id: 'agent-no-time',
                    text: 'stable',
                }],
            }],
        });

        expect(messages).toHaveLength(1);
        expect(messages[0].envelope.time).toBe(0);
    });
});
