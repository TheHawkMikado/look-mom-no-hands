/**
 * What a push notification points at. Pure so the parsing is unit-testable
 * without expo-notifications' native module.
 *
 * Server contract: the push payload's `data` carries `approvalId` for an
 * approval and `promptId` for a question; both may arrive as strings or
 * numbers depending on the sender.
 */
export type NotificationTarget =
  | { kind: "approval"; approvalId: string }
  | { kind: "prompt"; promptId: string }
  | null;

export function parseNotificationData(data: unknown): NotificationTarget {
  if (!data || typeof data !== "object") return null;
  const o = data as Record<string, unknown>;
  const approvalId = idOf(o.approvalId);
  if (approvalId) return { kind: "approval", approvalId };
  const promptId = idOf(o.promptId);
  if (promptId) return { kind: "prompt", promptId };
  return null;
}

function idOf(value: unknown): string | null {
  if (typeof value === "string") return value.trim() || null;
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}
