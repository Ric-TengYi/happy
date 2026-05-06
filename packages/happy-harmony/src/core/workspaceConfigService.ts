import type { KeyValueStore } from './storage';

const WORKSPACE_PATH_KEY = 'default-workspace-path';

export interface WorkspaceConfigService {
  getWorkspacePath(): string;
  setWorkspacePath(path: string | null): void;
  resolveNewSessionDefaultPath(machineDefaultPath: string): string;
}

export function createWorkspaceConfigService(options: { storage: KeyValueStore }): WorkspaceConfigService {
  return {
    getWorkspacePath() {
      return options.storage.getString(WORKSPACE_PATH_KEY) ?? '';
    },
    setWorkspacePath(path) {
      const trimmed = path?.trim();
      if (trimmed) {
        options.storage.setString(WORKSPACE_PATH_KEY, trimmed);
      } else {
        options.storage.remove(WORKSPACE_PATH_KEY);
      }
    },
    resolveNewSessionDefaultPath(machineDefaultPath) {
      const workspacePath = this.getWorkspacePath().trim();
      return workspacePath.length > 0 ? workspacePath : machineDefaultPath;
    },
  };
}
