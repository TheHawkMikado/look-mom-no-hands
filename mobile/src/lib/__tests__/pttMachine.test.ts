import { transition } from "../pttMachine";

describe("pttMachine", () => {
  it("starts recognition on pressIn from idle", () => {
    expect(transition("idle", "pressIn")).toEqual({
      state: "holding",
      effect: "startHoldRecognition",
    });
  });

  it("sends the transcript on release while holding", () => {
    expect(transition("holding", "pressOut")).toEqual({
      state: "idle",
      effect: "sendAndStopRecognition",
    });
  });

  it("locks when sliding up while holding", () => {
    expect(transition("holding", "slideToLock")).toEqual({
      state: "locked",
      effect: "enterLockedListening",
    });
  });

  it("keeps listening when the finger lifts after locking", () => {
    expect(transition("locked", "pressOut")).toEqual({
      state: "locked",
      effect: null,
    });
  });

  it("stops the locked session on tap", () => {
    expect(transition("locked", "tapStop")).toEqual({
      state: "idle",
      effect: "stopListening",
    });
  });

  it("ignores events that do not apply to the current state", () => {
    expect(transition("idle", "pressOut")).toEqual({ state: "idle", effect: null });
    expect(transition("idle", "tapStop")).toEqual({ state: "idle", effect: null });
    expect(transition("idle", "slideToLock")).toEqual({ state: "idle", effect: null });
    expect(transition("holding", "pressIn")).toEqual({ state: "holding", effect: null });
    expect(transition("holding", "tapStop")).toEqual({ state: "holding", effect: null });
    expect(transition("locked", "pressIn")).toEqual({ state: "locked", effect: null });
    expect(transition("locked", "slideToLock")).toEqual({ state: "locked", effect: null });
  });

  it("supports a full hold-lock-stop round trip", () => {
    let s = transition("idle", "pressIn");
    s = transition(s.state, "slideToLock");
    s = transition(s.state, "pressOut");
    expect(s.state).toBe("locked");
    s = transition(s.state, "tapStop");
    expect(s).toEqual({ state: "idle", effect: "stopListening" });
  });
});
