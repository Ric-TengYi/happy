import fs from 'fs/promises';
import os from 'os';
import path from 'path';

export interface DirectoryPickerEntry {
  name: string;
  path: string;
  type: 'directory';
  hidden: boolean;
}

export interface DirectoryPickerResult {
  path: string;
  parentPath: string | null;
  entries: DirectoryPickerEntry[];
  truncated: boolean;
}

export interface DirectoryPickerOptions {
  path?: string | null;
  showHidden?: boolean | null;
  limit?: number | null;
}

const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;

export async function listDirectoryEntriesForPicker(options: DirectoryPickerOptions = {}): Promise<DirectoryPickerResult> {
  const requestedPath = normalizeRequestedPath(options.path);
  const showHidden = options.showHidden === true;
  const limit = normalizeLimit(options.limit);
  const entries = await fs.readdir(requestedPath, { withFileTypes: true });

  const directories = entries
    .filter((entry) => entry.isDirectory())
    .filter((entry) => showHidden || !isHiddenName(entry.name))
    .map((entry): DirectoryPickerEntry => ({
      name: entry.name,
      path: path.join(requestedPath, entry.name),
      type: 'directory',
      hidden: isHiddenName(entry.name),
    }))
    .sort(compareDirectoryEntries);

  return {
    path: requestedPath,
    parentPath: getParentPath(requestedPath),
    entries: directories.slice(0, limit),
    truncated: directories.length > limit,
  };
}

function normalizeRequestedPath(value: string | null | undefined): string {
  const trimmed = typeof value === 'string' ? value.trim() : '';
  if (trimmed.length === 0 || trimmed === '~') {
    return os.homedir();
  }
  if (trimmed.startsWith('~/')) {
    return path.join(os.homedir(), trimmed.slice(2));
  }
  return path.resolve(trimmed);
}

function normalizeLimit(value: number | null | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return DEFAULT_LIMIT;
  }
  return Math.min(MAX_LIMIT, Math.max(1, Math.floor(value)));
}

function getParentPath(value: string): string | null {
  const parent = path.dirname(value);
  return parent === value ? null : parent;
}

function isHiddenName(name: string): boolean {
  return name.startsWith('.');
}

function compareDirectoryEntries(a: DirectoryPickerEntry, b: DirectoryPickerEntry): number {
  return a.name.localeCompare(b.name, 'en', { sensitivity: 'base' });
}
