import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const WORKSPACE_PREFS: string = 'happy-workspace-config';
const WORKSPACE_PATH_KEY: string = 'default-workspace-path';

export function getWorkspacePath(context: common.UIAbilityContext): string {
  const store = preferences.getPreferencesSync(context, { name: WORKSPACE_PREFS });
  const stored = store.getSync(WORKSPACE_PATH_KEY, '') as string;
  return stored.trim();
}

export async function setWorkspacePath(context: common.UIAbilityContext, path: string): Promise<void> {
  const trimmed = path.trim();
  const store = preferences.getPreferencesSync(context, { name: WORKSPACE_PREFS });
  if (trimmed.length > 0) {
    store.putSync(WORKSPACE_PATH_KEY, trimmed);
  } else {
    store.deleteSync(WORKSPACE_PATH_KEY);
  }
  await store.flush();
}
