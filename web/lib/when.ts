/**
 * Task timing (SPEC.md §5.4). Extraction hands us the user's time phrase
 * verbatim ("by 3", "Friday", "end of day"); this turns it into a `due_at`
 * in the account's timezone and derives the two clocks the follow-up engine
 * runs on: `check_in_at` (nudge the owner) and `escalate_at` (bring it to the
 * user as a question).
 *
 * Deterministic on purpose. A wrong guess costs one "did you mean Friday?";
 * a model call on the confirmation path costs the 5-second budget (§1).
 * Everything here is pure and timezone-explicit so it can be unit-tested
 * with a fixed clock.
 */

export const DEFAULT_TZ = "America/New_York";

export interface WhenOptions {
  now: Date;
  tz?: string;
}

export interface WhenResult {
  at: Date;
  /** Which rule fired — on the receipt so a bad parse is diagnosable. */
  rule: string;
}

// MARK: - Timezone helpers (no library: Intl is enough)

interface LocalParts {
  year: number;
  month: number; // 1–12
  day: number;
  hour: number;
  minute: number;
  second: number;
  /** 0 = Sunday */
  weekday: number;
}

const WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];

const fmtCache = new Map<string, Intl.DateTimeFormat>();
function formatter(tz: string): Intl.DateTimeFormat {
  let f = fmtCache.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hourCycle: "h23",
      year: "numeric", month: "numeric", day: "numeric",
      hour: "numeric", minute: "numeric", second: "numeric",
      weekday: "short",
    });
    fmtCache.set(tz, f);
  }
  return f;
}

/** A valid IANA zone, else the default. A bad setting must never 500 intake. */
export function safeTz(tz: string | null | undefined): string {
  if (!tz) return DEFAULT_TZ;
  try {
    formatter(tz);
    return tz;
  } catch {
    return DEFAULT_TZ;
  }
}

export function localParts(d: Date, tz: string): LocalParts {
  const parts = formatter(tz).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "0";
  const wd = get("weekday").toLowerCase().slice(0, 3);
  return {
    year: Number(get("year")),
    month: Number(get("month")),
    day: Number(get("day")),
    hour: Number(get("hour")) % 24,
    minute: Number(get("minute")),
    second: Number(get("second")),
    weekday: Math.max(0, WEEKDAYS.findIndex((w) => w.startsWith(wd))),
  };
}

/** Offset of `tz` from UTC at instant `d`, in ms. */
function offsetMs(d: Date, tz: string): number {
  const p = localParts(d, tz);
  const asUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return asUtc - Math.floor(d.getTime() / 1000) * 1000;
}

/** Wall-clock time in `tz` → instant. Two passes so a DST edge resolves. */
export function zonedToUtc(p: { year: number; month: number; day: number; hour?: number; minute?: number }, tz: string): Date {
  const wall = Date.UTC(p.year, p.month - 1, p.day, p.hour ?? 0, p.minute ?? 0, 0);
  let guess = new Date(wall - offsetMs(new Date(wall), tz));
  guess = new Date(wall - offsetMs(guess, tz));
  return guess;
}

function addDays(p: LocalParts, days: number): { year: number; month: number; day: number } {
  const d = new Date(Date.UTC(p.year, p.month - 1, p.day + days));
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

// MARK: - Phrase parsing

const EOD = { hour: 17, minute: 0 };
const START = { hour: 9, minute: 0 };
const DAYPART: Record<string, { hour: number; minute: number }> = {
  morning: START,
  noon: { hour: 12, minute: 0 },
  midday: { hour: 12, minute: 0 },
  lunch: { hour: 12, minute: 0 },
  afternoon: { hour: 15, minute: 0 },
  evening: { hour: 18, minute: 0 },
  tonight: { hour: 20, minute: 0 },
  night: { hour: 20, minute: 0 },
  midnight: { hour: 23, minute: 59 },
  "end of day": EOD,
  "end of the day": EOD,
  "close of business": EOD,
  eod: EOD,
  cob: EOD,
  "end of business": EOD,
};

const TIME_RE = /\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.|o'?clock)?\b/i;

/** "3", "3pm", "3:30", "15:00" → hour/minute, or null. Bare hours read the
 *  way people say them: "by 3" is 3 pm, "by 9" is 9 am. */
export function parseClock(s: string): { hour: number; minute: number; explicit: boolean } | null {
  const m = TIME_RE.exec(s);
  if (!m) return null;
  let hour = Number(m[1]);
  const minute = m[2] ? Number(m[2]) : 0;
  const suffix = (m[3] ?? "").toLowerCase().replace(/\./g, "");
  if (hour > 23 || minute > 59) return null;
  if (suffix === "pm" && hour < 12) hour += 12;
  else if (suffix === "am" && hour === 12) hour = 0;
  else if (!suffix || suffix === "oclock") {
    // No am/pm. 24h forms ("15:00") stand; a 1–7 is the afternoon one.
    if (hour >= 1 && hour <= 7) hour += 12;
  }
  return { hour, minute, explicit: !!suffix || !!m[2] || hour >= 13 };
}

/**
 * The parser. Returns null when the phrase means nothing to us; the caller
 * then falls back to the no-due-date defaults rather than inventing a time.
 */
export function parseWhen(phrase: string | null | undefined, opts: WhenOptions): WhenResult | null {
  if (!phrase) return null;
  const tz = safeTz(opts.tz);
  const now = opts.now;
  const here = localParts(now, tz);
  const s = phrase.trim().toLowerCase().replace(/\s+/g, " ").replace(/^(by|before|until|till|due|on|at|for)\s+/, "");
  if (!s) return null;

  // "asap", "now", "right away"
  if (/^(asap|now|right away|immediately|urgent(ly)?)$/.test(s)) {
    return { at: new Date(now.getTime() + 60 * 60_000), rule: "asap" };
  }

  // "in 2 hours", "in 30 minutes", "in a week", "in 3 days"
  const rel = /^in\s+(an?|\d+)\s*(minute|min|hour|hr|day|week|month)s?$/.exec(s);
  if (rel) {
    const n = rel[1] === "a" || rel[1] === "an" ? 1 : Number(rel[1]);
    const unit = rel[2];
    if (unit === "minute" || unit === "min") return { at: new Date(now.getTime() + n * 60_000), rule: "relative" };
    if (unit === "hour" || unit === "hr") return { at: new Date(now.getTime() + n * 3_600_000), rule: "relative" };
    if (unit === "day") return { at: zonedToUtc({ ...addDays(here, n), ...EOD }, tz), rule: "relative" };
    if (unit === "week") return { at: zonedToUtc({ ...addDays(here, 7 * n), ...EOD }, tz), rule: "relative" };
    if (unit === "month") return { at: zonedToUtc({ year: here.year, month: here.month + n, day: here.day, ...EOD }, tz), rule: "relative" };
  }

  // Which day? Default today; overridden by the words below.
  let day = { year: here.year, month: here.month, day: here.day };
  let dayRule: string | null = null;
  let daySaid = false;

  if (/\btomorrow\b/.test(s)) {
    day = addDays(here, 1); dayRule = "tomorrow"; daySaid = true;
  } else if (/\b(day after tomorrow)\b/.test(s)) {
    day = addDays(here, 2); dayRule = "day-after"; daySaid = true;
  } else if (/\bnext week\b/.test(s)) {
    day = addDays(here, ((8 - here.weekday) % 7) || 7); dayRule = "next-week"; daySaid = true; // next Monday
  } else if (/\b(end of (the )?week|eow)\b/.test(s)) {
    const toFri = (5 - here.weekday + 7) % 7;
    day = addDays(here, toFri); dayRule = "end-of-week"; daySaid = true;
  } else if (/\bend of (the )?month\b/.test(s)) {
    day = { year: here.year, month: here.month + 1, day: 0 }; // day 0 of next month = last day of this one
    const d = new Date(Date.UTC(day.year, day.month - 1, day.day));
    day = { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
    dayRule = "end-of-month"; daySaid = true;
  } else if (/\bnext month\b/.test(s)) {
    day = { year: here.year, month: here.month + 1, day: 1 }; dayRule = "next-month"; daySaid = true;
  } else {
    const wd = /\b(next\s+|this\s+)?(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tue|tues|wed|thu|thur|thurs|fri|sat)\b/.exec(s);
    if (wd) {
      const target = WEEKDAYS.findIndex((w) => w.startsWith(wd[2].slice(0, 3)));
      let ahead = (target - here.weekday + 7) % 7;
      // "Friday" on a Friday means today unless the clock has already passed
      // (handled below); "next Friday" is the one after.
      if (wd[1]?.trim() === "next") ahead = ahead === 0 ? 7 : ahead + 7;
      day = addDays(here, ahead); dayRule = wd[1]?.trim() === "next" ? "next-weekday" : "weekday"; daySaid = true;
    } else {
      // "sept 20", "september 20th", "9/20", "the 20th"
      const md = /\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b/.exec(s)
        ?? /\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b/.exec(s);
      const slash = /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/.exec(s);
      const ordinal = /\bthe\s+(\d{1,2})(?:st|nd|rd|th)\b/.exec(s);
      if (md) {
        const monthTok = /^\d/.test(md[1]) ? md[2] : md[1];
        const dayTok = /^\d/.test(md[1]) ? md[1] : md[2];
        const month = MONTHS.findIndex((m) => m.startsWith(monthTok.slice(0, 3))) + 1;
        day = { year: here.year, month, day: Number(dayTok) };
        if (month < here.month || (month === here.month && Number(dayTok) < here.day)) day.year++;
        dayRule = "month-day"; daySaid = true;
      } else if (slash) {
        const year = slash[3] ? (slash[3].length === 2 ? 2000 + Number(slash[3]) : Number(slash[3])) : here.year;
        day = { year, month: Number(slash[1]), day: Number(slash[2]) };
        if (!slash[3] && (day.month < here.month || (day.month === here.month && day.day < here.day))) day.year++;
        dayRule = "slash-date"; daySaid = true;
      } else if (ordinal) {
        const d = Number(ordinal[1]);
        day = { year: here.year, month: here.month + (d < here.day ? 1 : 0), day: d };
        dayRule = "ordinal"; daySaid = true;
      } else if (/\btoday\b/.test(s)) {
        dayRule = "today"; daySaid = true;
      }
    }
  }

  // Which time? A clock beats a day-part beats end-of-day.
  let clock: { hour: number; minute: number } | null = null;
  let timeRule: string | null = null;
  const part = Object.keys(DAYPART).find((k) => new RegExp(`\\b${k.replace(/ /g, "\\s+")}\\b`).test(s));
  const c = parseClock(s.replace(/\b\d{1,2}\/\d{1,2}(\/\d{2,4})?\b/, "").replace(/\bthe\s+\d{1,2}(st|nd|rd|th)\b/, "").replace(/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?\b/, "").replace(/\b\d{1,2}(st|nd|rd|th)\s+(of\s+)?[a-z]+\b/, ""));
  if (c) { clock = c; timeRule = "clock"; }
  else if (part) { clock = DAYPART[part]; timeRule = part; }
  if (!clock) {
    if (!daySaid) return null; // nothing we recognise
    clock = EOD; timeRule = "eod";
  }

  let at = zonedToUtc({ ...day, ...clock }, tz);
  // A time already behind us today rolls to tomorrow ("by 3" said at 4 pm);
  // a bare 8–11 said in the evening means the morning.
  if (!daySaid && at.getTime() <= now.getTime()) {
    at = zonedToUtc({ ...addDays(here, 1), ...clock }, tz);
    dayRule = "rolled-to-tomorrow";
  } else if (dayRule === "weekday" && at.getTime() <= now.getTime()) {
    at = zonedToUtc({ ...addDays(here, 7), ...clock }, tz);
    dayRule = "weekday-next";
  }
  return { at, rule: [dayRule ?? "today", timeRule].join("+") };
}

// MARK: - Scheduling math (SPEC.md §5.4)

export const HOUR = 3_600_000;
export const DEFAULT_CHECK_IN_MS = 24 * HOUR;
export const DEFAULT_ESCALATE_MS = 48 * HOUR;

export interface Schedule {
  due_at: Date | null;
  check_in_at: Date;
  escalate_at: Date;
}

/**
 * check_in = halfway to the due time, but never later than an hour before it
 * (and never in the past); escalate = an hour after due. With no due time,
 * check in after a day and escalate after two.
 */
export function schedule(due: Date | null, now: Date): Schedule {
  if (!due) {
    return {
      due_at: null,
      check_in_at: new Date(now.getTime() + DEFAULT_CHECK_IN_MS),
      escalate_at: new Date(now.getTime() + DEFAULT_ESCALATE_MS),
    };
  }
  const lead = due.getTime() - now.getTime();
  const checkIn = Math.max(now.getTime(), due.getTime() - Math.max(lead / 2, HOUR));
  return {
    due_at: due,
    check_in_at: new Date(checkIn),
    escalate_at: new Date(due.getTime() + HOUR),
  };
}

/** After a "nudge again" answer: the next check-in is the next working
 *  morning in the account's zone (or `at` when the user named one), and the
 *  escalation is a day after that. */
export function reschedule(now: Date, tz: string, at?: Date | null): Schedule {
  const next = at ?? nextMorning(now, tz);
  return { due_at: next, check_in_at: next, escalate_at: new Date(next.getTime() + 24 * HOUR) };
}

export function nextMorning(now: Date, tz: string): Date {
  const here = localParts(now, safeTz(tz));
  let d = addDays(here, 1);
  let wd = (here.weekday + 1) % 7;
  while (wd === 0 || wd === 6) { d = addDays({ ...here, ...d }, 1); wd = (wd + 1) % 7; }
  return zonedToUtc({ ...d, ...START }, safeTz(tz));
}

/** "Friday morning", "tomorrow at 3 pm" — for the escalation question. */
export function describe(at: Date, now: Date, tz: string): string {
  const z = safeTz(tz);
  const a = localParts(at, z);
  const n = localParts(now, z);
  const dayDiff = Math.round((Date.UTC(a.year, a.month - 1, a.day) - Date.UTC(n.year, n.month - 1, n.day)) / 86_400_000);
  const dayWord = dayDiff === 0 ? "today" : dayDiff === 1 ? "tomorrow" : dayDiff < 7 ? WEEKDAYS[a.weekday].replace(/^./, (c) => c.toUpperCase()) : `${MONTHS[a.month - 1].slice(0, 3)} ${a.day}`;
  const h12 = ((a.hour + 11) % 12) + 1;
  const timeWord = a.minute === 0 ? `${h12} ${a.hour < 12 ? "am" : "pm"}` : `${h12}:${String(a.minute).padStart(2, "0")} ${a.hour < 12 ? "am" : "pm"}`;
  if (a.hour === 9 && a.minute === 0) return `${dayWord} morning`;
  return `${dayWord} at ${timeWord}`;
}

/** Is the wall clock in `tz` inside [start, end)? Handles overnight windows
 *  ("22:00"–"07:00"). Empty/invalid bounds mean no quiet hours. */
export function inQuietHours(now: Date, tz: string, start: string | null, end: string | null): boolean {
  const a = hm(start);
  const b = hm(end);
  if (a == null || b == null || a === b) return false;
  const p = localParts(now, safeTz(tz));
  const t = p.hour * 60 + p.minute;
  return a < b ? t >= a && t < b : t >= a || t < b;
}

/** The next instant the quiet window ends, or `now` when not in it. */
export function quietHoursEnd(now: Date, tz: string, start: string | null, end: string | null): Date {
  if (!inQuietHours(now, tz, start, end)) return now;
  const z = safeTz(tz);
  const b = hm(end)!;
  const p = localParts(now, z);
  const t = p.hour * 60 + p.minute;
  const day = t < b ? { year: p.year, month: p.month, day: p.day } : addDays(p, 1);
  return zonedToUtc({ ...day, hour: Math.floor(b / 60), minute: b % 60 }, z);
}

/** "HH:MM" → minutes since midnight, or null. */
export function hm(s: string | null | undefined): number | null {
  if (!s) return null;
  const m = /^(\d{1,2}):(\d{2})$/.exec(s.trim());
  if (!m) return null;
  const h = Number(m[1]);
  const mi = Number(m[2]);
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}

/** Local calendar date "YYYY-MM-DD" in `tz` — the daily brief's dedupe key. */
export function localDate(now: Date, tz: string): string {
  const p = localParts(now, safeTz(tz));
  return `${p.year}-${String(p.month).padStart(2, "0")}-${String(p.day).padStart(2, "0")}`;
}

/** Has the wall clock in `tz` passed "HH:MM" today? */
export function pastLocalTime(now: Date, tz: string, at: string | null): boolean {
  const m = hm(at);
  if (m == null) return false;
  const p = localParts(now, safeTz(tz));
  return p.hour * 60 + p.minute >= m;
}
