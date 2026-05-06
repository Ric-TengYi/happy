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

describe('workspace UI source', () => {
  test('uses saved workspace as the new session default only when home-relative paths can be resolved', () => {
    const defaultDirectorySource = sourceBlock('private getMachineDefaultDirectory(machine: HappyMachine)');
    const resolveSource = sourceBlock('private resolveMachineSpawnPath(path: string, machine: HappyMachine)');
    const spawnSource = sourceBlock('private spawnNewSessionFromPanel()');

    expect(defaultDirectorySource).toContain('workspace.length > 0 && this.canResolveMachinePath(workspace, machine)');
    expect(defaultDirectorySource).toContain('const homeDir = this.getMachinePathHomeDir(machine);');
    expect(resolveSource).toContain('const homeDir = this.getMachinePathHomeDir(machine);');
    expect(indexSource).toContain('private getMachinePathHomeDir(machine: HappyMachine): string');
    expect(indexSource).toContain("happyHomeDir.endsWith('/.happy')");
    expect(spawnSource).toContain('当前终端缺少主目录信息，请使用绝对路径');
  });

  test('clears stale directory parent state while loading a new directory', () => {
    const loadSource = sourceBlock('private loadDirectoryPickerPath(machine: HappyMachine, path: string)');

    expect(loadSource).toContain("this.directoryPickerParentPath = '';");
  });

  test('clears pending archive state when control plane data is reset', () => {
    const clearSource = sourceBlock('private clearControlPlaneData(status: string)');

    expect(clearSource).toContain('this.pendingArchivedSessionIds = [];');
    expect(clearSource).toContain("this.archivingSessionId = '';");
    expect(clearSource).toContain("this.sessionArchiveStatus = '';");
  });
});
