import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, test } from 'vitest';

const testDir = dirname(fileURLToPath(import.meta.url));
const indexSource = readFileSync(resolve(testDir, '../../entry/src/main/ets/pages/Index.ets'), 'utf8');

function sourceBlock(marker: string): string {
  const start = indexSource.indexOf(marker);
  expect(start).toBeGreaterThanOrEqual(0);
  const openBrace = indexSource.indexOf('{', start);
  expect(openBrace).toBeGreaterThanOrEqual(0);
  let depth = 0;
  for (let index = openBrace; index < indexSource.length; index += 1) {
    const char = indexSource[index];
    if (char === '{') {
      depth += 1;
    } else if (char === '}') {
      depth -= 1;
      if (depth === 0) {
        return indexSource.slice(start, index + 1);
      }
    }
  }
  throw new Error(`Could not find source block for ${marker}`);
}

describe('session detail UI source', () => {
  test('wires message history to a scroller and jump control', () => {
    const screenSource = sourceBlock('private SessionDetailScreen()');

    expect(indexSource).toContain('@State private showJumpToLatestButton: boolean = false;');
    expect(indexSource).toContain('private messageScroller: Scroller = new Scroller();');
    expect(indexSource).toContain('private messageScrollAwayDistance: number = 0;');
    expect(screenSource).toContain('Scroll(this.messageScroller)');
    expect(screenSource).toContain('this.handleMessageDidScroll();');
    expect(screenSource).toContain('this.markMessagesAtLatest();');
    expect(screenSource).toContain('if (this.showJumpToLatestButton)');
    expect(screenSource).toContain('this.JumpToLatestButton()');
  });

  test('jump control uses the down arrow and scrolls to latest from its own click handler', () => {
    const buttonSource = sourceBlock('private JumpToLatestButton()');

    expect(buttonSource).toContain('sys.symbol.arrow_down');
    expect(buttonSource).toContain('.onClick(() => {');
    expect(buttonSource).toContain('this.scrollMessagesToLatest(true);');
  });

  test('scroll state is cumulative and resets when the latest edge is reached', () => {
    const scrollSource = sourceBlock('private handleMessageDidScroll()');
    const latestSource = sourceBlock('private markMessagesAtLatest()');
    const resetSource = sourceBlock('private resetMessageScrollState()');

    expect(scrollSource).toContain('this.messageScrollAwayDistance += Math.abs(scrollDeltaY);');
    expect(scrollSource).toContain('if (this.messageScrollAwayDistance > 4)');
    expect(latestSource).toContain('this.showJumpToLatestButton = false;');
    expect(latestSource).toContain('this.messageScrollAwayDistance = 0;');
    expect(resetSource).toContain('this.messageScrollAwayDistance = 0;');
  });

  test('message refresh preserves position when jump control is visible', () => {
    const refreshSource = sourceBlock('private async refreshSelectedSessionMessagesAsync');

    expect(refreshSource).toContain('const shouldHoldScrollPosition = this.showJumpToLatestButton;');
    expect(refreshSource).toContain('} else if (shouldHoldScrollPosition) {');
    expect(refreshSource).toContain('this.showJumpToLatestButton = true;');
    expect(refreshSource).toContain('this.scrollMessagesToLatest(false);');
  });

  test('header refresh imports Codex thread history before loading messages', () => {
    const screenSource = sourceBlock('private SessionDetailScreen()');
    const headerRefreshSource = sourceBlock('private refreshSelectedSessionFromHeader()');
    const syncSource = sourceBlock('private async syncSelectedCodexThreadAsync');
    const canSyncSource = sourceBlock('private canSyncSelectedCodexThread(session: HappySession)');

    expect(indexSource).toContain('syncCodexThread,');
    expect(screenSource).toContain('this.refreshSelectedSessionFromHeader();');
    expect(headerRefreshSource).toContain('this.canSyncSelectedCodexThread(session)');
    expect(headerRefreshSource).toContain("this.messageStatus = '正在同步 Codex 历史...';");
    expect(syncSource).toContain('await syncCodexThread(');
    expect(syncSource).toContain('await this.refreshSelectedSessionMessagesAsync(generation, serverUrl, session);');
    expect(syncSource).toContain("await this.refreshSelectedSessionMessagesAsync(generation, serverUrl, session, 'Codex 同步失败');");
    expect(canSyncSource).toContain("flavor === 'codex'");
    expect(canSyncSource).toContain('machine.active');
  });

  test('message refresh can keep a status notice after fallback loading', () => {
    const refreshSource = sourceBlock('private async refreshSelectedSessionMessagesAsync');

    expect(refreshSource).toContain('statusNotice: string =');
    expect(refreshSource).toContain('const baseMessageStatus = snapshot.decodeWarningCount > 0');
    expect(refreshSource).toContain('statusNotice.length > 0');
  });
});
