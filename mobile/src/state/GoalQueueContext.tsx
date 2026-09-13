import React, {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { AppState } from "react-native";
import { GoalKind, submitGoal } from "../lib/api";
import { GoalQueue, MemoryQueueStore, QueuedGoal, SubmitOutcome } from "../lib/goalQueue";
import { createQueueStore } from "../lib/goalQueueStorage";

/** How often to retry a blocked queue on its own. Foreground transitions and
 *  successful feed polls also trigger a flush, so this is only a backstop. */
const RETRY_MS = 15000;

export interface GoalQueueContextValue {
  /** Goals waiting for the network, oldest first. */
  pending: readonly QueuedGoal[];
  submit: (text: string, kind: GoalKind) => Promise<SubmitOutcome>;
  /** Attempt delivery now; safe to call often (single-flight, no-op when empty). */
  flush: () => void;
}

export const GoalQueueContext = createContext<GoalQueueContextValue | null>(null);

export function useGoalQueue(): GoalQueueContextValue {
  const value = useContext(GoalQueueContext);
  if (!value) throw new Error("useGoalQueue outside GoalQueueProvider");
  return value;
}

function sendQueued(goal: QueuedGoal): Promise<void> {
  return submitGoal(goal.text, goal.kind).then(() => undefined);
}

export function GoalQueueProvider({ children }: { children: React.ReactNode }) {
  // The queue object is created once per signed-in session and swaps its
  // store to SecureStore as soon as that's known to be available.
  const queueRef = useRef<GoalQueue | null>(null);
  if (!queueRef.current) {
    queueRef.current = new GoalQueue({ store: new MemoryQueueStore(), send: sendQueued });
  }
  const [queue, setQueue] = useState<GoalQueue>(queueRef.current);
  const [pending, setPending] = useState<readonly QueuedGoal[]>([]);

  useEffect(() => {
    let alive = true;
    void createQueueStore().then(async (store) => {
      if (!alive) return;
      const persistent = new GoalQueue({ store, send: sendQueued });
      // Anything that hit the boot-time memory queue (a goal spoken in the
      // first few ms, offline) follows what was persisted last session.
      const bootstrap = queueRef.current;
      queueRef.current = persistent;
      if (bootstrap) {
        await bootstrap.ready;
        for (const g of bootstrap.pending) await persistent.enqueue(g.text, g.kind);
      }
      if (alive) setQueue(persistent);
    });
    return () => {
      alive = false;
    };
  }, []);

  useEffect(() => queue.subscribe((items) => setPending([...items])), [queue]);

  // Backstop retry + flush on return to foreground.
  useEffect(() => {
    if (pending.length === 0) return;
    void queue.flush();
    const interval = setInterval(() => void queue.flush(), RETRY_MS);
    const sub = AppState.addEventListener("change", (state) => {
      if (state === "active") void queue.flush();
    });
    return () => {
      clearInterval(interval);
      sub.remove();
    };
  }, [queue, pending.length]);

  const value = useMemo<GoalQueueContextValue>(
    () => ({
      pending,
      submit: (text, kind) => queue.submit(text, kind),
      flush: () => void queue.flush(),
    }),
    [queue, pending],
  );

  return <GoalQueueContext.Provider value={value}>{children}</GoalQueueContext.Provider>;
}
