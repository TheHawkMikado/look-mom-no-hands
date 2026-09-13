import { isClockTime, normalizeClockTime } from "../clock";

describe("clock times", () => {
  it("accepts 24h HH:MM", () => {
    expect(isClockTime("22:00")).toBe(true);
    expect(isClockTime("7:30")).toBe(true);
    expect(isClockTime("23:59")).toBe(true);
  });

  it("rejects out-of-range and malformed values", () => {
    expect(isClockTime("24:00")).toBe(false);
    expect(isClockTime("12:60")).toBe(false);
    expect(isClockTime("noon")).toBe(false);
    expect(isClockTime("")).toBe(false);
  });

  it("zero-pads hours", () => {
    expect(normalizeClockTime("7:30")).toBe("07:30");
    expect(normalizeClockTime("bad")).toBeNull();
  });
});
