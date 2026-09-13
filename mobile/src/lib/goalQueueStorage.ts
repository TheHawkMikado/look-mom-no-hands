import * as SecureStore from "expo-secure-store";
import { MemoryQueueStore, QueuedGoal, QueueStore } from "./goalQueue";

/**
 * Persists the offline goal queue in SecureStore — already a dependency (the
 * bearer token lives there), and goals are the user's own words so they
 * deserve the same protection as the token.
 *
 * One key per goal plus an index of ids: SecureStore values are meant to be
 * small (iOS warns above 2 KB), so a single blob holding many goals would
 * blow through that on the first long dictation. Per-item keys keep each
 * value close to the goal's own size.
 */
const INDEX_KEY = "nohands_goal_queue_index";
const ITEM_PREFIX = "nohands_goal_queue_item_";

export class SecureQueueStore implements QueueStore {
  private knownIds: string[] = [];

  async load(): Promise<QueuedGoal[]> {
    const raw = await SecureStore.getItemAsync(INDEX_KEY);
    const ids = parseIds(raw);
    const items: QueuedGoal[] = [];
    for (const id of ids) {
      const itemRaw = await SecureStore.getItemAsync(ITEM_PREFIX + id);
      const item = parseItem(itemRaw);
      if (item) items.push(item);
    }
    this.knownIds = items.map((i) => i.id);
    return items;
  }

  async save(items: QueuedGoal[]): Promise<void> {
    const nextIds = items.map((i) => i.id);
    const previous = new Set(this.knownIds);
    // Items first, index last: a crash mid-save leaves stray item keys (which
    // load() ignores) rather than an index pointing at nothing.
    for (const item of items) {
      if (previous.has(item.id)) continue; // goals are immutable once queued
      await SecureStore.setItemAsync(ITEM_PREFIX + item.id, JSON.stringify(item));
    }
    await SecureStore.setItemAsync(INDEX_KEY, JSON.stringify(nextIds));
    const keep = new Set(nextIds);
    for (const id of this.knownIds) {
      if (!keep.has(id)) await SecureStore.deleteItemAsync(ITEM_PREFIX + id);
    }
    this.knownIds = nextIds;
  }
}

/** SecureStore is unavailable on web and some emulators — fall back to memory
 *  so the Talk screen still works (the queue just won't survive a restart). */
export async function createQueueStore(): Promise<QueueStore> {
  try {
    if (await SecureStore.isAvailableAsync()) return new SecureQueueStore();
  } catch {
    // fall through
  }
  return new MemoryQueueStore();
}

function parseIds(raw: string | null): string[] {
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((x): x is string => typeof x === "string") : [];
  } catch {
    return [];
  }
}

function parseItem(raw: string | null): QueuedGoal | null {
  if (!raw) return null;
  try {
    const o = JSON.parse(raw) as Partial<QueuedGoal>;
    if (typeof o.id !== "string" || typeof o.text !== "string") return null;
    return {
      id: o.id,
      text: o.text,
      kind: o.kind === "dictation" ? "dictation" : "goal",
      queuedAt: typeof o.queuedAt === "string" ? o.queuedAt : new Date(0).toISOString(),
    };
  } catch {
    return null;
  }
}
