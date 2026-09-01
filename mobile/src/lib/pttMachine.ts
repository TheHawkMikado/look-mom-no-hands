/**
 * Push-to-talk state machine, kept pure so the hold/slide/lock gesture logic
 * is testable without any UI or speech plumbing. The UI dispatches events and
 * performs the returned effect.
 */

export type PttState = "idle" | "holding" | "locked";

export type PttEvent = "pressIn" | "slideToLock" | "pressOut" | "tapStop";

/** Side effect the caller must perform after a transition. */
export type PttEffect =
  | "startHoldRecognition" // begin capturing a single utterance
  | "sendAndStopRecognition" // stop capturing and send the transcript as a goal
  | "enterLockedListening" // switch to continuous wake-phrase listening
  | "stopListening"; // end the locked session entirely

export interface PttTransition {
  state: PttState;
  effect: PttEffect | null;
}

export function transition(state: PttState, event: PttEvent): PttTransition {
  switch (state) {
    case "idle":
      if (event === "pressIn") {
        return { state: "holding", effect: "startHoldRecognition" };
      }
      break;
    case "holding":
      if (event === "pressOut") {
        return { state: "idle", effect: "sendAndStopRecognition" };
      }
      if (event === "slideToLock") {
        return { state: "locked", effect: "enterLockedListening" };
      }
      break;
    case "locked":
      if (event === "tapStop") {
        return { state: "idle", effect: "stopListening" };
      }
      // pressOut here is the finger lifting off after sliding to the lock —
      // the whole point of locking is that release must NOT end the session.
      break;
  }
  return { state, effect: null };
}
