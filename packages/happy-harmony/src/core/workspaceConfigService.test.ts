import { describe, expect, it } from 'vitest';
import { createMemoryKeyValueStore } from './storage';
import { createWorkspaceConfigService } from './workspaceConfigService';

describe('WorkspaceConfigService', () => {
  it('persists a trimmed default workspace path and clears empty values', () => {
    const storage = createMemoryKeyValueStore();
    const service = createWorkspaceConfigService({ storage });

    expect(service.getWorkspacePath()).toBe('');

    service.setWorkspacePath(' ~/uniubi/work/IdeaProjects/happy ');

    expect(createWorkspaceConfigService({ storage }).getWorkspacePath()).toBe('~/uniubi/work/IdeaProjects/happy');

    service.setWorkspacePath('   ');

    expect(createWorkspaceConfigService({ storage }).getWorkspacePath()).toBe('');
  });

  it('uses the workspace path as the new session default when configured', () => {
    const service = createWorkspaceConfigService({ storage: createMemoryKeyValueStore() });

    expect(service.resolveNewSessionDefaultPath('/Users/tengyi')).toBe('/Users/tengyi');

    service.setWorkspacePath('~/project');

    expect(service.resolveNewSessionDefaultPath('/Users/tengyi')).toBe('~/project');
  });
});
