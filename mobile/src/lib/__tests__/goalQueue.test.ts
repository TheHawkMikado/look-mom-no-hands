import { ApiError } from "../api";
import {
  classifyFailure,
  flushInOrder,
  GoalQueue,
  MemoryQueueStore,
  QueuedGoal,
} from "../goalQueue";

const offline = () => new TypeError("Network request failed");

function makeSend(behavior: (goal: QueuedGoal, attempt: number) => void) {
  const calls: string[] = [];
  const attempts = new Map<string, number>();
  const send = jest.fn(async (goal: QueuedGoal) => {
    const n = (attempts.get(goal.id) ?? 0) + 1;
    attempts.set(goal.id, n);
    calls.push(goal.text);
    behavior(goal, n);
  });
  return { send, calls, attempts };
}

let counter = 0;
const ids = () => `g${++counter}`;
beforeEach(() => {
  counter = 0;
});

describe("classifyFailure", () => {
  it("retries network errors, 5xx and 429", () => {
    expect(classifyFailure(offline())).toBe("retry");
    expect(classifyFailure(new ApiError("boom", 503))).toBe("retry");
    expect(classifyFailure(new ApiError("slow down", 429))).toBe("retry");
  });

  it("drops 4xx including 401 (already signed out)", () => {
    expect(classifyFailure(new ApiError("empty", 400))).toBe("drop");
    expect(classifyFailure(new ApiError("signed out", 401))).toBe("drop");
  });
});

describe("flushInOrder", () => {
  const goal = (id: string, text = id): QueuedGoal => ({
    id,
    text,
    kind: "goal",
    queuedAt: "2026-01-01T00:00:00.000Z",
  });

  it("sends everything in order when online", async () => {
    const { send, calls } = makeSend(() => undefined);
    const result = await flushInOrder([goal("a"), goal("b"), goal("c")], send);
    expect(calls).toEqual(["a", "b", "c"]);
    expect(result.remaining).toEqual([]);
    expect(result.blocked).toBe(false);
  });

  it("stops at the first retryable failure and keeps order", async () => {
    const { send, calls } = makeSend((g) => {
      if (g.id === "b") throw offline();
    });
    const result = await flushInOrder([goal("a"), goal("b"), goal("c")], send);
    expect(calls).toEqual(["a", "b"]);
    expect(result.sent.map((g) => g.id)).toEqual(["a"]);
    expect(result.remaining.map((g) => g.id)).toEqual(["b", "c"]);
    expect(result.blocked).toBe(true);
  });

  it("drops a rejected goal and continues", async () => {
    const { send, calls } = makeSend((g) => {
      if (g.id === "b") throw new ApiError("empty goal", 400);
    });
    const result = await flushInOrder([goal("a"), goal("b"), goal("c")], send);
    expect(calls).toEqual(["a", "b", "c"]);
    expect(result.dropped.map((g) => g.id)).toEqual(["b"]);
    expect(result.remaining).toEqual([]);
  });
});

describe("GoalQueue", () => {
  it("sends directly when nothing is queued", async () => {
    const store = new MemoryQueueStore();
    const { send } = makeSend(() => undefined);
    const q = new GoalQueue({ store, send, newId: ids });
    await expect(q.submit("open safari", "goal")).resolves.toBe("sent");
    expect(q.pending).toHaveLength(0);
    expect(await store.load()).toEqual([]);
  });

  it("queues and persists when offline, then flushes in order when back", async () => {
    const store = new MemoryQueueStore();
    let online = false;
    const { send, calls } = makeSend(() => {
      if (!online) throw offline();
    });
    const q = new GoalQueue({ store, send, newId: ids, now: () => 1000 });

    await expect(q.submit("first", "goal")).resolves.toBe("queued");
    await expect(q.submit("second", "dictation")).resolves.toBe("queued");
    expect(q.pending.map((g) => g.text)).toEqual(["first", "second"]);
    expect((await store.load()).map((g) => g.text)).toEqual(["first", "second"]);
    // Only the head is retried while blocked — nothing behind it was tried.
    expect(calls).toEqual(["first", "first"]);

    online = true;
    const result = await q.flush();
    expect(result.sent.map((g) => g.text)).toEqual(["first", "second"]);
    expect(calls.slice(2)).toEqual(["first", "second"]);
    expect(q.pending).toHaveLength(0);
    expect(await store.load()).toEqual([]);
    expect(send.mock.calls.at(-1)?.[0]).toMatchObject({
      text: "second",
      kind: "dictation",
      queuedAt: "1970-01-01T00:00:01.000Z",
    });
  });

  it("puts a new goal behind queued ones even once online again", async () => {
    const store = new MemoryQueueStore();
    let online = false;
    const { send, calls } = makeSend(() => {
      if (!online) throw offline();
    });
    const q = new GoalQueue({ store, send, newId: ids });
    await q.submit("earlier", "goal");
    online = true;
    await expect(q.submit("later", "goal")).resolves.toBe("sent");
    expect(calls.filter((_, i) => i > 0)).toEqual(["earlier", "later"]);
  });

  it("loads what a previous session left behind, ahead of new goals", async () => {
    const store = new MemoryQueueStore([
      { id: "old", text: "from last time", kind: "goal", queuedAt: "2026-01-01T00:00:00.000Z" },
    ]);
    const { send, calls } = makeSend(() => undefined);
    const q = new GoalQueue({ store, send, newId: ids });
    await expect(q.submit("new one", "goal")).resolves.toBe("sent");
    expect(calls).toEqual(["from last time", "new one"]);
  });

  it("throws non-retryable errors on a direct send instead of queueing", async () => {
    const store = new MemoryQueueStore();
    const { send } = makeSend(() => {
      throw new ApiError("empty goal", 400);
    });
    const q = new GoalQueue({ store, send, newId: ids });
    await expect(q.submit("", "goal")).rejects.toBeInstanceOf(ApiError);
    expect(q.pending).toHaveLength(0);
  });

  it("notifies subscribers and shares one in-flight flush", async () => {
    const store = new MemoryQueueStore();
    let release: () => void = () => undefined;
    const gate = new Promise<void>((r) => {
      release = r;
    });
    let online = false;
    const send = jest.fn(async () => {
      if (!online) throw offline();
      await gate;
    });
    const q = new GoalQueue({ store, send, newId: ids });
    await q.ready;
    const seen: number[] = [];
    q.subscribe((items) => seen.push(items.length));
    await q.submit("a", "goal");
    online = true;
    const p1 = q.flush();
    const p2 = q.flush();
    expect(p1).toBe(p2);
    release();
    await p1;
    expect(send).toHaveBeenCalledTimes(2);
    expect(seen).toEqual([0, 1, 0]);
  });
});
