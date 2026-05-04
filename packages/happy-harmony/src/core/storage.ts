export interface KeyValueStore {
  getString(key: string): string | null;
  setString(key: string, value: string): void;
  remove(key: string): void;
}

export function createMemoryKeyValueStore(initial?: Record<string, string>): KeyValueStore {
  const values = new Map<string, string>(Object.entries(initial ?? {}));
  return {
    getString(key) {
      return values.get(key) ?? null;
    },
    setString(key, value) {
      values.set(key, value);
    },
    remove(key) {
      values.delete(key);
    },
  };
}
