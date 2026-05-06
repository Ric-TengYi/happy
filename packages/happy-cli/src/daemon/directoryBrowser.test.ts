import fs from 'fs/promises';
import os from 'os';
import path from 'path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { listDirectoryEntriesForPicker } from './directoryBrowser';

let rootDir = '';

describe('listDirectoryEntriesForPicker', () => {
  beforeEach(async () => {
    rootDir = await fs.mkdtemp(path.join(os.tmpdir(), 'happy-dir-picker-'));
    await fs.mkdir(path.join(rootDir, 'alpha'));
    await fs.mkdir(path.join(rootDir, 'Beta'));
    await fs.mkdir(path.join(rootDir, '.secret'));
    await fs.writeFile(path.join(rootDir, 'file.txt'), 'not a directory');
  });

  afterEach(async () => {
    if (rootDir.length > 0) {
      await fs.rm(rootDir, { recursive: true, force: true });
    }
  });

  it('lists only visible child directories by default', async () => {
    const result = await listDirectoryEntriesForPicker({ path: rootDir });

    expect(result.path).toBe(rootDir);
    expect(result.parentPath).toBe(path.dirname(rootDir));
    expect(result.entries.map((entry) => entry.name)).toEqual(['alpha', 'Beta']);
    expect(result.entries.every((entry) => entry.type === 'directory')).toBe(true);
  });

  it('can include hidden directories and limit the result', async () => {
    const result = await listDirectoryEntriesForPicker({
      path: rootDir,
      showHidden: true,
      limit: 2,
    });

    expect(result.entries.map((entry) => entry.name)).toEqual(['.secret', 'alpha']);
    expect(result.truncated).toBe(true);
  });
});
