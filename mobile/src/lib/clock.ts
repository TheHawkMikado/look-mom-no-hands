/** "HH:MM" 24-hour clock strings, as the settings API stores them. */
export function isClockTime(value: string): boolean {
  const m = /^(\d{1,2}):(\d{2})$/.exec(value.trim());
  if (!m) return false;
  const h = Number(m[1]);
  const min = Number(m[2]);
  return h >= 0 && h <= 23 && min >= 0 && min <= 59;
}

/** Zero-pads "9:5" → "09:05"; returns null for anything that isn't a time. */
export function normalizeClockTime(value: string): string | null {
  if (!isClockTime(value)) return null;
  const [h, m] = value.trim().split(":");
  return `${h.padStart(2, "0")}:${m}`;
}

/** The phone's IANA zone, or null on runtimes that don't expose it. */
export function deviceTimeZone(): string | null {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone ?? null;
  } catch {
    return null;
  }
}
