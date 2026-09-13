/**
 * Offline queue for spoken/typed goals. Pure: storage and the network send are
 * injected, so the whole thing runs under jest with in-memory fakes.
 *
 * Semantics:
 *  - Goals are delivered strictly in the order they were queued. A flush stops
 *    at the first goal that fails for a retryable reason (offline, 5xx) and
 *    keeps it at the head; everything behind it waits.
 *  - A goal that fails for a non-retryable reason (4xx: the server rejected
 *    the goal itself) is dropped so it can't wedge the queue forever.
 *  - Once anything is queued, new goals go BEHIND it rather than straight to
 *    the network — "open Safari, then close it" must not arrive reversed.
 */
import { ApiError, GoalKind } from "./api";

export interface QueuedGoal {
  id: string;
  text: string;
  kind: GoalKind;
  /** ISO timestamp of when the phone queued it. */
  queuedAt: string;
}

export interface QueueStore {
  load(): Promise<QueuedGoal[]>;
  save(items: QueuedGoal[]): Promise<void>;
}

export type QueueSend = (goal: QueuedGoal) => Promise<void>;
export type FailureClass = "retry" | "drop";

export interface FlushResult {
  sent: QueuedGoal[];
  dropped: QueuedGoal[];
  remaining: QueuedGoal[];
  /** True when the flush stopped on a retryable failure (still offline). */
  blocked: boolean;
}

export type SubmitOutcome = "sent" | "queued";

/**
 * Default failure classification. A 401 is "drop" because the api client has
 * already signed the user out — the queued goals belong to a session that no
 * longer exists. Other 4xx are the server rejecting the goal (empty text, too
 * long) which a retry cannot fix. Everything else — fetch's TypeError when
 * there's no network, 5xx, 429 — is worth retrying later.
 */
export function classifyFailure(error: unknown): FailureClass {
  if (error instanceof ApiError) {
    if (error.status === 429) return "retry";
    if (error.status >= 400 && error.status < 500) return "drop";
    return "retry";
  }
  return "retry";
}

/** In-memory store for tests and as a fallback when secure storage is unavailable. */
export class MemoryQueueStore implements QueueStore {
  constructor(private items: QueuedGoal[] = []) {}
  async load(): Promise<QueuedGoal[]> {
    return [...this.items];
  }
  async save(items: QueuedGoal[]): Promise<void> {
    this.items = [...items];
  }
}

export function newQueueId(now: number = Date.now()): string {
  return `${now.toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

/** Send `items` in order; see the module comment for stop/drop rules. */
export async function flushInOrder(
  items: readonly QueuedGoal[],
  send: QueueSend,
  classify: (error: unknown) => FailureClass = classifyFailure,
): Promise<FlushResult> {
  const sent: QueuedGoal[] = [];
  const dropped: QueuedGoal[] = [];
  for (let i = 0; i < items.length; i++) {
    const goal = items[i];
    try {
      await send(goal);
      sent.push(goal);
    } catch (error) {
      if (classify(error) === "drop") {
        dropped.push(goal);
        continue;
      }
      return { sent, dropped, remaining: items.slice(i), blocked: true };
    }
  }
  return { sent, dropped, remaining: [], blocked: false };
}

export interface GoalQueueOptions {
  store: QueueStore;
  send: QueueSend;
  classify?: (error: unknown) => FailureClass;
  now?: () => number;
  newId?: () => string;
}

export class GoalQueue {
  private items: QueuedGoal[] = [];
  private listeners = new Set<(items: readonly QueuedGoal[]) => void>();
  private inflight: Promise<FlushResult> | null = null;
  private readonly store: QueueStore;
  private readonly send: QueueSend;
  private readonly classify: (error: unknown) => FailureClass;
  private readonly now: () => number;
  private readonly newId: () => string;
  /** Resolves once persisted items have been loaded. */
  readonly ready: Promise<void>;

  constructor(opts: GoalQueueOptions) {
    this.store = opts.store;
    this.send = opts.send;
    this.classify = opts.classify ?? classifyFailure;
    this.now = opts.now ?? Date.now;
    this.newId = opts.newId ?? newQueueId;
    this.ready = this.store
      .load()
      .then((loaded) => {
        // Anything queued before boot goes ahead of anything queued during it.
        this.items = [...loaded, ...this.items];
        this.emit();
      })
      .catch(() => undefined);
  }

  get pending(): readonly QueuedGoal[] {
    return this.items;
  }

  subscribe(listener: (items: readonly QueuedGoal[]) => void): () => void {
    this.listeners.add(listener);
    listener(this.items);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private emit(): void {
    for (const l of this.listeners) l(this.items);
  }

  private async persist(): Promise<void> {
    try {
      await this.store.save(this.items);
    } catch {
      // Storage failing must not lose the in-memory queue; the next persist retries.
    }
  }

  async enqueue(text: string, kind: GoalKind): Promise<QueuedGoal> {
    await this.ready;
    const goal: QueuedGoal = {
      id: this.newId(),
      text,
      kind,
      queuedAt: new Date(this.now()).toISOString(),
    };
    this.items = [...this.items, goal];
    this.emit();
    await this.persist();
    return goal;
  }

  /** Try to drain the queue. Single-flight: concurrent callers share one pass. */
  flush(): Promise<FlushResult> {
    if (this.inflight) return this.inflight;
    this.inflight = (async () => {
      await this.ready;
      const before = this.items;
      if (before.length === 0) {
        return { sent: [], dropped: [], remaining: [], blocked: false };
      }
      const result = await flushInOrder(before, this.send, this.classify);
      const consumed = new Set([...result.sent, ...result.dropped].map((g) => g.id));
      // Keep anything enqueued while the pass ran (it sits behind `before`).
      this.items = this.items.filter((g) => !consumed.has(g.id));
      this.emit();
      await this.persist();
      return result;
    })().finally(() => {
      this.inflight = null;
    });
    return this.inflight;
  }

  /**
   * The Talk screen's entry point. Sends directly when nothing is waiting;
   * otherwise queues behind what's there and attempts a flush. Throws only for
   * non-retryable failures with an empty queue (the caller shows the error);
   * a retryable failure queues the goal and resolves "queued".
   */
  async submit(text: string, kind: GoalKind): Promise<SubmitOutcome> {
    await this.ready;
    if (this.items.length === 0 && !this.inflight) {
      const goal: QueuedGoal = {
        id: this.newId(),
        text,
        kind,
        queuedAt: new Date(this.now()).toISOString(),
      };
      try {
        await this.send(goal);
        return "sent";
      } catch (error) {
        if (this.classify(error) === "drop") throw error;
        this.items = [...this.items, goal];
        this.emit();
        await this.persist();
        return "queued";
      }
    }
    const goal = await this.enqueue(text, kind);
    const result = await this.flush();
    return result.sent.some((g) => g.id === goal.id) ? "sent" : "queued";
  }
}
