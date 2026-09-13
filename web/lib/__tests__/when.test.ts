import { test } from "node:test";
import assert from "node:assert/strict";
import {
  describe,
  inQuietHours,
  localDate,
  localParts,
  nextMorning,
  parseWhen,
  quietHoursEnd,
  reschedule,
  schedule,
  zonedToUtc,
  HOUR,
} from "../when";

// Fixed clock: Wednesday 2026-09-16 10:00 in New York (EDT, UTC-4) = 14:00Z.
const TZ = "America/New_York";
const NOW = new Date("2026-09-16T14:00:00Z");
const local = (d: Date) => {
  const p = localParts(d, TZ);
  return `${p.year}-${String(p.month).padStart(2, "0")}-${String(p.day).padStart(2, "0")} ${String(p.hour).padStart(2, "0")}:${String(p.minute).padStart(2, "0")}`;
};
const at = (phrase: string) => {
  const r = parseWhen(phrase, { now: NOW, tz: TZ });
  assert.ok(r, `no parse for "${phrase}"`);
  return local(r.at);
};

test("bare hours read the way people say them", () => {
  assert.equal(at("by 3"), "2026-09-16 15:00");
  assert.equal(at("3pm"), "2026-09-16 15:00");
  assert.equal(at("at 3:30 pm"), "2026-09-16 15:30");
  assert.equal(at("by 11"), "2026-09-16 11:00");
  assert.equal(at("15:00"), "2026-09-16 15:00");
  assert.equal(at("noon"), "2026-09-16 12:00");
});

test("a time already behind us rolls to tomorrow", () => {
  assert.equal(at("by 9am"), "2026-09-17 09:00");
  assert.equal(at("by 9"), "2026-09-17 09:00");
});

test("days: today, tomorrow, weekdays, next week, end of day", () => {
  assert.equal(at("end of day"), "2026-09-16 17:00");
  assert.equal(at("eod"), "2026-09-16 17:00");
  assert.equal(at("tonight"), "2026-09-16 20:00");
  assert.equal(at("tomorrow"), "2026-09-17 17:00");
  assert.equal(at("tomorrow morning"), "2026-09-17 09:00");
  assert.equal(at("tomorrow at 2"), "2026-09-17 14:00");
  assert.equal(at("Friday"), "2026-09-18 17:00");
  assert.equal(at("by friday morning"), "2026-09-18 09:00");
  assert.equal(at("next friday"), "2026-09-25 17:00");
  assert.equal(at("Wednesday"), "2026-09-16 17:00", "today's weekday with time ahead is today");
  assert.equal(at("Wednesday at 9am"), "2026-09-23 09:00", "today's weekday with time passed is next week");
  assert.equal(at("next week"), "2026-09-21 17:00");
  assert.equal(at("end of week"), "2026-09-18 17:00");
  assert.equal(at("end of month"), "2026-09-30 17:00");
});

test("relative and calendar phrases", () => {
  assert.equal(at("in 2 hours"), "2026-09-16 12:00");
  assert.equal(at("in 30 minutes"), "2026-09-16 10:30");
  assert.equal(at("in 3 days"), "2026-09-19 17:00");
  assert.equal(at("in a week"), "2026-09-23 17:00");
  assert.equal(at("sept 20"), "2026-09-20 17:00");
  assert.equal(at("October 2nd at 10am"), "2026-10-02 10:00");
  assert.equal(at("9/20"), "2026-09-20 17:00");
  assert.equal(at("the 20th"), "2026-09-20 17:00");
  assert.equal(at("1/5"), "2027-01-05 17:00", "a past month means next year");
});

test("nonsense parses to nothing rather than a guess", () => {
  assert.equal(parseWhen("when you can", { now: NOW, tz: TZ }), null);
  assert.equal(parseWhen("", { now: NOW, tz: TZ }), null);
  assert.equal(parseWhen(null, { now: NOW, tz: TZ }), null);
});

test("timezone is honoured: the same phrase lands at a different instant in LA", () => {
  const ny = parseWhen("by 3", { now: NOW, tz: TZ })!.at;
  const la = parseWhen("by 3", { now: NOW, tz: "America/Los_Angeles" })!.at;
  assert.equal(la.getTime() - ny.getTime(), 3 * HOUR);
  const bad = parseWhen("by 3", { now: NOW, tz: "Mars/Olympus" })!.at;
  assert.equal(bad.getTime(), ny.getTime(), "an invalid zone falls back to the default");
});

test("DST edge resolves to a real instant", () => {
  // 2026-11-01 02:30 does not exist in New York; the parser must not throw.
  const d = zonedToUtc({ year: 2026, month: 11, day: 1, hour: 2, minute: 30 }, TZ);
  assert.ok(Number.isFinite(d.getTime()));
});

test("schedule: check-in halfway, at least an hour before, escalate an hour after", () => {
  const due = new Date(NOW.getTime() + 6 * HOUR);
  const s = schedule(due, NOW);
  assert.equal(s.check_in_at.getTime(), NOW.getTime() + 3 * HOUR);
  assert.equal(s.escalate_at.getTime(), due.getTime() + HOUR);

  const soon = schedule(new Date(NOW.getTime() + 90 * 60_000), NOW);
  assert.equal(soon.check_in_at.getTime(), NOW.getTime() + 30 * 60_000, "1h before wins over halfway when due is close");

  const imminent = schedule(new Date(NOW.getTime() + 20 * 60_000), NOW);
  assert.equal(imminent.check_in_at.getTime(), NOW.getTime(), "never in the past");
});

test("schedule: no due date means 24h / 48h", () => {
  const s = schedule(null, NOW);
  assert.equal(s.due_at, null);
  assert.equal(s.check_in_at.getTime(), NOW.getTime() + 24 * HOUR);
  assert.equal(s.escalate_at.getTime(), NOW.getTime() + 48 * HOUR);
});

test("reschedule lands on the next working morning", () => {
  assert.equal(local(nextMorning(NOW, TZ)), "2026-09-17 09:00");
  const friday = new Date("2026-09-18T14:00:00Z");
  assert.equal(local(nextMorning(friday, TZ)), "2026-09-21 09:00", "Friday → Monday");
  const r = reschedule(NOW, TZ);
  assert.equal(r.escalate_at.getTime() - r.check_in_at.getTime(), 24 * HOUR);
  assert.equal(describe(r.check_in_at, NOW, TZ), "tomorrow morning");
  assert.equal(describe(new Date("2026-09-18T19:30:00Z"), NOW, TZ), "Friday at 3:30 pm");
});

test("quiet hours: overnight window, and when it ends", () => {
  const late = new Date("2026-09-17T03:00:00Z"); // 23:00 EDT Wed
  assert.equal(inQuietHours(late, TZ, "22:00", "07:00"), true);
  assert.equal(inQuietHours(NOW, TZ, "22:00", "07:00"), false);
  assert.equal(inQuietHours(NOW, TZ, null, null), false);
  assert.equal(local(quietHoursEnd(late, TZ, "22:00", "07:00")), "2026-09-17 07:00");
  assert.equal(quietHoursEnd(NOW, TZ, "22:00", "07:00").getTime(), NOW.getTime());
  const early = new Date("2026-09-17T09:30:00Z"); // 05:30 EDT Thu
  assert.equal(local(quietHoursEnd(early, TZ, "22:00", "07:00")), "2026-09-17 07:00");
  assert.equal(localDate(late, TZ), "2026-09-16");
});
