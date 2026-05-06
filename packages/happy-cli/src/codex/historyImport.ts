import { createEnvelope, type SessionEnvelope } from '@slopus/happy-wire';

export type CodexHistoryUserInput = {
    type: string;
    text?: string;
    text_elements?: unknown[];
    url?: string;
    path?: string;
    name?: string;
};

export type CodexHistoryItem = {
    type: string;
    id: string;
    content?: CodexHistoryUserInput[];
    text?: string;
    phase?: unknown;
    memoryCitation?: unknown;
    summary?: string[];
    contentItems?: unknown[] | null;
    command?: string;
    cwd?: string;
    source?: unknown;
    status?: unknown;
    commandActions?: unknown[];
    aggregatedOutput?: string | null;
    exitCode?: number | null;
    durationMs?: number | null;
    changes?: unknown;
    server?: string;
    tool?: string;
    arguments?: unknown;
    result?: unknown;
    error?: unknown;
};

export type CodexHistoryTurn = {
    id: string;
    items: CodexHistoryItem[];
    status?: unknown;
    error?: unknown;
    startedAt?: number | null;
    completedAt?: number | null;
};

export type CodexHistoryThread = {
    id: string;
    name?: string | null;
    preview?: string;
    cwd?: string;
    turns?: CodexHistoryTurn[];
};

export type ImportedCodexSessionMessage = {
    localId: string;
    envelope: SessionEnvelope;
};

const MAX_IMPORTED_EVENTS = 80;

function localId(threadId: string, turnId: string, itemId: string): string {
    return `codex-import:${threadId}:${turnId}:${itemId}`;
}

function turnImportId(threadId: string, turnId: string): string {
    return `codex-import:${threadId}:${turnId}`;
}

function turnTime(turn: CodexHistoryTurn, fallbackOffset: number): number {
    if (typeof turn.startedAt === 'number' && Number.isFinite(turn.startedAt)) {
        return turn.startedAt * 1000;
    }
    return fallbackOffset;
}

function userInputToText(input: CodexHistoryUserInput): string {
    if (input.type === 'text' && typeof input.text === 'string') {
        return input.text;
    }
    if ((input.type === 'image' || input.type === 'localImage') && typeof input.path === 'string') {
        return `[图片] ${input.path}`;
    }
    if (input.type === 'image' && typeof input.url === 'string') {
        return `[图片] ${input.url}`;
    }
    if ((input.type === 'mention' || input.type === 'skill') && typeof input.name === 'string') {
        return `@${input.name}`;
    }
    return '';
}

function pushMessage(
    messages: ImportedCodexSessionMessage[],
    thread: CodexHistoryThread,
    turn: CodexHistoryTurn,
    itemKey: string,
    envelope: SessionEnvelope,
): void {
    messages.push({
        localId: localId(thread.id, turn.id, itemKey),
        envelope,
    });
}

function mapItem(
    messages: ImportedCodexSessionMessage[],
    thread: CodexHistoryThread,
    turn: CodexHistoryTurn,
    item: CodexHistoryItem,
    time: number,
): void {
    const turnId = turnImportId(thread.id, turn.id);

    if (item.type === 'userMessage') {
        const text = (item.content ?? []).map(userInputToText).filter(Boolean).join('\n').trim();
        if (text.length === 0) {
            return;
        }
        pushMessage(messages, thread, turn, item.id, createEnvelope('user', { t: 'text', text }, {
            id: localId(thread.id, turn.id, item.id),
            turn: turnId,
            time,
        }));
        return;
    }

    if (item.type === 'agentMessage' && typeof item.text === 'string' && item.text.trim().length > 0) {
        pushMessage(messages, thread, turn, item.id, createEnvelope('agent', { t: 'text', text: item.text }, {
            id: localId(thread.id, turn.id, item.id),
            turn: turnId,
            time,
        }));
        return;
    }

    if (item.type === 'reasoning') {
        const text = [
            ...(Array.isArray(item.summary) ? item.summary : []),
            ...(Array.isArray(item.contentItems) ? item.contentItems.map(String) : []),
        ].join('\n').trim();
        if (text.length === 0) {
            return;
        }
        pushMessage(messages, thread, turn, item.id, createEnvelope('agent', { t: 'text', text, thinking: true }, {
            id: localId(thread.id, turn.id, item.id),
            turn: turnId,
            time,
        }));
        return;
    }

    if (item.type === 'plan' && typeof item.text === 'string' && item.text.trim().length > 0) {
        pushMessage(messages, thread, turn, item.id, createEnvelope('agent', { t: 'text', text: item.text, thinking: true }, {
            id: localId(thread.id, turn.id, item.id),
            turn: turnId,
            time,
        }));
        return;
    }

    if (item.type === 'commandExecution') {
        return;
    }

    if (item.type === 'fileChange') {
        return;
    }

    if (item.type === 'mcpToolCall' || item.type === 'dynamicToolCall') {
        return;
    }
}

export function mapCodexThreadToSessionProtocolMessages(thread: CodexHistoryThread): ImportedCodexSessionMessage[] {
    const turns = Array.isArray(thread.turns) ? thread.turns : [];
    const turnMessages = turns.map((turn, index) => mapTurn(thread, turn, index));
    const selected: ImportedCodexSessionMessage[] = [];

    for (let index = turnMessages.length - 1; index >= 0; index -= 1) {
        const messages = turnMessages[index];
        if (messages.length === 0) {
            continue;
        }
        if (selected.length === 0 && messages.length > MAX_IMPORTED_EVENTS) {
            selected.unshift(...messages.slice(messages.length - MAX_IMPORTED_EVENTS));
            break;
        }
        if (selected.length + messages.length > MAX_IMPORTED_EVENTS) {
            break;
        }
        selected.unshift(...messages);
    }

    return selected;
}

function mapTurn(
    thread: CodexHistoryThread,
    turn: CodexHistoryTurn,
    fallbackOffset: number,
): ImportedCodexSessionMessage[] {
    const messages: ImportedCodexSessionMessage[] = [];
    const time = turnTime(turn, fallbackOffset);

    for (const item of turn.items ?? []) {
        mapItem(messages, thread, turn, item, time);
    }

    return messages;
}
