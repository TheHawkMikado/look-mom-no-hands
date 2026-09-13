import { sql } from "@/lib/db";
import { assertCloudWritable } from "@/lib/residency";
import { DEFAULT_TZ, hm, safeTz } from "@/lib/when";

/**
 * Per-account settings the follow-up engine needs to be polite: which clock
 * the user lives on, when not to speak, when the daily brief is due, and
 * whether the phone should buzz. These are settings about the *app*, not
 * facts about the user's life — a timezone and a "don't talk after 10 pm"
 * are cloud-resident by the §4.3 rule; preferences about people, places
 * and money stay in the Local Brain.
 */

export interface AccountSettings {
  email: string;
  tz: string;
  /** "HH:MM" local, or null for no quiet hours. */
  quiet_hours_start: string | null;
  quiet_hours_end: string | null;
  /** "HH:MM" local, or null to skip the daily brief. */
  daily_brief_at: string | null;
  push_enabled: boolean;
  /** Highest tier a human ticket is sent at without asking (§6: team-facing
   *  is tier 2 and asks by default; the owner can raise this). */
  auto_deliver_tier: number;
  /** Local date the last daily brief was created on — the dedupe key. */
  last_brief_date: string | null;
  residency: "cloud";
  updated_at: Date;
}

export const DEFAULT_SETTINGS: Omit<AccountSettings, "email" | "updated_at"> = {
  tz: DEFAULT_TZ,
  quiet_hours_start: "22:00",
  quiet_hours_end: "07:00",
  daily_brief_at: "08:00",
  push_enabled: true,
  auto_deliver_tier: 1,
  last_brief_date: null,
  residency: "cloud",
};

export function ensureSettingsSchema(db = sql()) {
  return db`
    CREATE TABLE IF NOT EXISTS account_settings (
      email              text PRIMARY KEY,
      tz                 text NOT NULL DEFAULT 'America/New_York',
      quiet_hours_start  text,
      quiet_hours_end    text,
      daily_brief_at     text,
      push_enabled       boolean NOT NULL DEFAULT true,
      auto_deliver_tier  smallint NOT NULL DEFAULT 1 CHECK (auto_deliver_tier BETWEEN 0 AND 4),
      last_brief_date    text,
      residency          text NOT NULL DEFAULT 'cloud' CHECK (residency IN ('local','cloud')),
      updated_at         timestamptz NOT NULL DEFAULT now()
    )`;
}

const norm = (email: string) => email.trim().toLowerCase();

/** Never null: an account with no row gets the defaults. */
export async function getSettings(email: string): Promise<AccountSettings> {
  const rows = await sql()<AccountSettings[]>`SELECT * FROM account_settings WHERE email = ${norm(email)}`;
  const r = rows[0];
  if (!r) return { email: norm(email), updated_at: new Date(0), ...DEFAULT_SETTINGS };
  return { ...r, tz: safeTz(r.tz) };
}

export type SettingsPatch = Partial<Pick<AccountSettings, "tz" | "quiet_hours_start" | "quiet_hours_end" | "daily_brief_at" | "push_enabled" | "auto_deliver_tier" | "last_brief_date">>;

/** Validates as it goes: a bad zone or a malformed "HH:MM" is dropped, not
 *  stored, so the engine never has to defend against its own settings. */
export function cleanSettingsPatch(input: Record<string, unknown>): SettingsPatch {
  const p: SettingsPatch = {};
  if (typeof input.tz === "string") p.tz = safeTz(input.tz);
  for (const k of ["quiet_hours_start", "quiet_hours_end", "daily_brief_at"] as const) {
    if (k in input) {
      const v = input[k];
      p[k] = v == null || v === "" ? null : hm(String(v)) == null ? undefined : String(v).trim();
      if (p[k] === undefined) delete p[k];
    }
  }
  if (typeof input.push_enabled === "boolean") p.push_enabled = input.push_enabled;
  if (input.auto_deliver_tier != null && Number.isFinite(Number(input.auto_deliver_tier))) {
    p.auto_deliver_tier = Math.min(4, Math.max(0, Math.round(Number(input.auto_deliver_tier))));
  }
  return p;
}

export async function setSettings(email: string, patch: SettingsPatch): Promise<AccountSettings> {
  const current = await getSettings(email);
  const row = assertCloudWritable({
    ...current,
    ...patch,
    kind: "account_settings",
    residency: "cloud" as const,
    email: norm(email),
  });
  const [out] = await sql()<AccountSettings[]>`
    INSERT INTO account_settings (email, tz, quiet_hours_start, quiet_hours_end, daily_brief_at, push_enabled, auto_deliver_tier, last_brief_date, residency, updated_at)
    VALUES (${row.email}, ${row.tz}, ${row.quiet_hours_start}, ${row.quiet_hours_end}, ${row.daily_brief_at}, ${row.push_enabled},
            ${row.auto_deliver_tier}, ${row.last_brief_date}, ${row.residency}, now())
    ON CONFLICT (email) DO UPDATE SET
      tz = EXCLUDED.tz, quiet_hours_start = EXCLUDED.quiet_hours_start, quiet_hours_end = EXCLUDED.quiet_hours_end,
      daily_brief_at = EXCLUDED.daily_brief_at, push_enabled = EXCLUDED.push_enabled,
      auto_deliver_tier = EXCLUDED.auto_deliver_tier, last_brief_date = EXCLUDED.last_brief_date, updated_at = now()
    RETURNING *`;
  return out;
}

/** Accounts the follow-up engine should visit: anyone with a task on a
 *  clock, plus anyone with a daily brief configured. */
export async function accountsWithFollowups(): Promise<string[]> {
  const rows = await sql()<{ email: string }[]>`
    SELECT DISTINCT email FROM tasks
     WHERE closed_at IS NULL AND status NOT IN ('done','failed','denied')
    UNION
    SELECT email FROM account_settings WHERE daily_brief_at IS NOT NULL`;
  return rows.map((r) => r.email);
}
