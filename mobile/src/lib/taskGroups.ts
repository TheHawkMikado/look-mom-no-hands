import type { Task, TaskStatus } from "./api";

/** The four buckets the Tasks screen shows, in display order. */
export type TaskGroupKey = "your_call" | "needs_approval" | "working" | "done";

export const TASK_GROUP_ORDER: readonly TaskGroupKey[] = [
  "your_call",
  "needs_approval",
  "working",
  "done",
];

export const TASK_GROUP_LABEL: Record<TaskGroupKey, string> = {
  your_call: "Your call",
  needs_approval: "Needs approval",
  working: "Working",
  done: "Done",
};

const GROUP_OF: Record<TaskStatus, TaskGroupKey> = {
  needs_decision: "your_call",
  awaiting_approval: "needs_approval",
  triaged: "working",
  dispatching: "working",
  in_progress: "working",
  approved: "working",
  assigned: "working",
  done: "done",
  denied: "done",
  failed: "done",
};

/** Unknown statuses (a newer server) land in "working" rather than vanishing. */
export function groupOfStatus(status: string): TaskGroupKey {
  return GROUP_OF[status as TaskStatus] ?? "working";
}

export interface TaskGroup {
  key: TaskGroupKey;
  label: string;
  tasks: Task[];
}

/** Buckets in display order; empty buckets are omitted. Input order is kept
 *  within a bucket (the API returns newest first). */
export function groupTasks(tasks: readonly Task[]): TaskGroup[] {
  const buckets = new Map<TaskGroupKey, Task[]>();
  for (const task of tasks) {
    const key = groupOfStatus(task.status);
    const list = buckets.get(key);
    if (list) list.push(task);
    else buckets.set(key, [task]);
  }
  return TASK_GROUP_ORDER.filter((key) => buckets.has(key)).map((key) => ({
    key,
    label: TASK_GROUP_LABEL[key],
    tasks: buckets.get(key) ?? [],
  }));
}

/** Tasks that are waiting on the owner — what the Tasks tab badge counts. */
export function countNeedingOwner(tasks: readonly Task[]): number {
  return tasks.filter((t) => {
    const g = groupOfStatus(t.status);
    return g === "your_call" || g === "needs_approval";
  }).length;
}

/** Short human label for a task status, used in pills. */
export function taskStatusLabel(status: string): string {
  switch (status as TaskStatus) {
    case "triaged":
      return "Queued";
    case "dispatching":
      return "Dispatching";
    case "in_progress":
      return "In progress";
    case "awaiting_approval":
      return "Needs approval";
    case "approved":
      return "Approved";
    case "denied":
      return "Denied";
    case "assigned":
      return "Assigned";
    case "needs_decision":
      return "Your call";
    case "done":
      return "Done";
    case "failed":
      return "Failed";
    default:
      return status.replace(/_/g, " ");
  }
}
