import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import { AppState } from "react-native";
import {
  answerPrompt as apiAnswerPrompt,
  createTask,
  getOutstandingTasks,
  getPrompts,
  getTasks,
  IntakeResult,
  Prompt,
  Task,
  TaskSource,
} from "../lib/api";
import { countNeedingOwner } from "../lib/taskGroups";

/** Badge poll: cheap (outstanding + prompts), runs whenever the app is open. */
const BADGE_POLL_MS = 15000;
const LIST_LIMIT = 100;

interface TasksContextValue {
  tasks: Task[];
  prompts: Prompt[];
  loaded: boolean;
  /** Prompts + tasks waiting on the owner — the Tasks tab badge. */
  badgeCount: number;
  /** Full list + prompts (the Tasks screen calls this while visible). */
  refresh: () => Promise<void>;
  /** Badge-only refresh, also what a foreground push triggers. */
  refreshOutstanding: () => Promise<void>;
  answerPrompt: (id: string, answer: string) => Promise<void>;
  submitRequest: (text: string, source: TaskSource) => Promise<IntakeResult>;
}

const TasksContext = createContext<TasksContextValue | null>(null);

export function useTasks(): TasksContextValue {
  const value = useContext(TasksContext);
  if (!value) throw new Error("useTasks outside TasksProvider");
  return value;
}

export function TasksProvider({ children }: { children: React.ReactNode }) {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [prompts, setPrompts] = useState<Prompt[]>([]);
  const [outstanding, setOutstanding] = useState<Task[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [appActive, setAppActive] = useState(AppState.currentState === "active");

  const refresh = useCallback(async () => {
    // Prompts are the other agent's endpoint — its absence (404 during
    // rollout) must not blank the task list, so the two are settled separately.
    const [taskResult, promptResult] = await Promise.allSettled([
      getTasks({ limit: LIST_LIMIT }),
      getPrompts(),
    ]);
    if (taskResult.status === "fulfilled") {
      setTasks(taskResult.value);
      setLoaded(true);
    }
    if (promptResult.status === "fulfilled") setPrompts(promptResult.value);
  }, []);

  const refreshOutstanding = useCallback(async () => {
    const [taskResult, promptResult] = await Promise.allSettled([
      getOutstandingTasks(),
      getPrompts(),
    ]);
    if (taskResult.status === "fulfilled") setOutstanding(taskResult.value);
    if (promptResult.status === "fulfilled") setPrompts(promptResult.value);
  }, []);

  useEffect(() => {
    const sub = AppState.addEventListener("change", (state) => {
      setAppActive(state === "active");
    });
    return () => sub.remove();
  }, []);

  useEffect(() => {
    if (!appActive) return;
    void refreshOutstanding();
    const interval = setInterval(() => void refreshOutstanding(), BADGE_POLL_MS);
    return () => clearInterval(interval);
  }, [appActive, refreshOutstanding]);

  const answerPrompt = useCallback(
    async (id: string, answer: string) => {
      // Optimistic: the card leaves immediately; a failure brings it back.
      setPrompts((prev) => prev.filter((p) => p.id !== id));
      try {
        await apiAnswerPrompt(id, answer);
      } catch (e) {
        await refreshOutstanding();
        throw e;
      }
    },
    [refreshOutstanding],
  );

  const submitRequest = useCallback(
    async (text: string, source: TaskSource) => {
      const result = await createTask(text, source);
      if (result.task) {
        // Show the new task at the top right away; the next refresh reconciles.
        setTasks((prev) => [result.task as Task, ...prev.filter((t) => t.id !== result.task?.id)]);
      }
      void refreshOutstanding();
      return result;
    },
    [refreshOutstanding],
  );

  const badgeCount = useMemo(
    () => prompts.length + countNeedingOwner(outstanding),
    [prompts, outstanding],
  );

  const value = useMemo<TasksContextValue>(
    () => ({
      tasks,
      prompts,
      loaded,
      badgeCount,
      refresh,
      refreshOutstanding,
      answerPrompt,
      submitRequest,
    }),
    [tasks, prompts, loaded, badgeCount, refresh, refreshOutstanding, answerPrompt, submitRequest],
  );

  return <TasksContext.Provider value={value}>{children}</TasksContext.Provider>;
}
