/**
 * Data residency (SPEC.md §4.3).
 *
 * Every object the chief-of-staff layer stores is tagged `local` or `cloud`.
 * Local objects — audio, transcripts, contact details, anything the user says
 * about their life — live on the Mac and never reach this service. Cloud
 * objects are the sparse metadata the phone and the control plane need: task
 * titles, statuses, owners, receipts, routing scores.
 *
 * This module is the one choke point every cloud write goes through.
 * `residency.test.ts` fails the test run if a local object gets past it, so
 * the rule is enforced by the build, not by policy.
 */

export type Residency = "local" | "cloud";

export const RESIDENCY: readonly Residency[] = ["local", "cloud"] as const;

/** Object kinds that are local by construction and must never have a cloud
 *  table. `assertCloudWritable` rejects them by kind as well as by tag, so a
 *  mis-tagged transcript is still caught. */
export const LOCAL_ONLY_KINDS = [
  "person",
  "voiceprint",
  "session",
  "transcript",
  "audio",
  "contact",
  "preference",
] as const;
export type LocalOnlyKind = (typeof LOCAL_ONLY_KINDS)[number];

export interface Resident {
  /** What this object is — used for the kind-level check. */
  kind: string;
  residency: Residency;
}

export class ResidencyViolation extends Error {
  constructor(public readonly kind: string, public readonly residency: string) {
    super(`residency violation: refusing to write ${kind} (residency=${residency}) to a cloud store`);
    this.name = "ResidencyViolation";
  }
}

/**
 * Gate for every cloud write path. Throws rather than returning false so a
 * caller cannot forget to check the result. Text fields are also capped so a
 * task "detail" can never smuggle a transcript in: a cloud task carries what
 * fits on a phone card, not a meeting.
 */
export function assertCloudWritable<T extends Resident>(obj: T): T {
  if (obj.residency !== "cloud") throw new ResidencyViolation(obj.kind, obj.residency);
  if ((LOCAL_ONLY_KINDS as readonly string[]).includes(obj.kind)) {
    throw new ResidencyViolation(obj.kind, obj.residency);
  }
  return obj;
}

/** Cap for free-text columns on cloud objects (title/detail/summary). The
 *  relay's existing agent_events.detail cap is 500; tasks get a little more
 *  room for a draft excerpt, still far short of a transcript. */
export const CLOUD_TEXT_CAP = 2000;

export function capCloudText(s: string, cap = CLOUD_TEXT_CAP): string {
  const t = s.trim();
  return t.length > cap ? t.slice(0, cap - 1) + "…" : t;
}
