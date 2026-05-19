import { ApiSessionClient } from '@/api/apiSession';
import { logger } from '@/ui/logger';

import { CodexAppServerClient } from './codexAppServerClient';
import { mapCodexThreadToSessionProtocolMessages } from './historyImport';

export type CodexThreadHistoryImportResult = {
    threadId: string;
    imported: number;
};

export type CodexThreadHistoryReader = {
    readThread: (opts: {
        threadId: string;
        includeTurns?: boolean;
    }) => Promise<{ thread: unknown }>;
};

export type CodexThreadHistoryImportSession = Pick<ApiSessionClient, 'sendSessionProtocolMessage' | 'flushPendingMessages'>;

export async function importCodexThreadHistory(opts: {
    client: CodexThreadHistoryReader;
    session: CodexThreadHistoryImportSession;
    threadId: string;
}): Promise<CodexThreadHistoryImportResult> {
    const response = await opts.client.readThread({
        threadId: opts.threadId,
        includeTurns: true,
    });
    const imported = mapCodexThreadToSessionProtocolMessages(response.thread as any);

    for (const message of imported) {
        opts.session.sendSessionProtocolMessage(message.envelope, {
            localId: message.localId,
            invalidate: false,
        });
    }
    await opts.session.flushPendingMessages();

    return {
        threadId: opts.threadId,
        imported: imported.length,
    };
}

export async function importCodexThreadHistoryBestEffort(opts: {
    client: CodexThreadHistoryReader;
    session: CodexThreadHistoryImportSession;
    threadId: string;
}): Promise<CodexThreadHistoryImportResult> {
    try {
        return await importCodexThreadHistory(opts);
    } catch (error) {
        const reason = error instanceof Error ? error.message : String(error);
        logger.warn(`[codex] Failed to import Codex history for ${opts.threadId}: ${reason}`);
        return {
            threadId: opts.threadId,
            imported: 0,
        };
    }
}

export async function importCodexThreadHistoryWithTemporaryClient(opts: {
    session: CodexThreadHistoryImportSession;
    threadId: string;
}): Promise<CodexThreadHistoryImportResult> {
    const client = new CodexAppServerClient();
    try {
        await client.connect();
        return await importCodexThreadHistory({
            client,
            session: opts.session,
            threadId: opts.threadId,
        });
    } finally {
        await client.disconnect();
    }
}
